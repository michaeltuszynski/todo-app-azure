data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}

# Create an Azure AD application
resource "azuread_application" "this" {
  display_name = "TerraformAcmeDnsChallengeAppService"
}

# Create a service principal for the Azure AD application
resource "azuread_service_principal" "this" {
  application_id = azuread_application.this.application_id
}

# Create a client secret for the Azure AD application
resource "azuread_application_password" "this" {
  application_object_id = azuread_application.this.object_id
  end_date_relative     = "8760h" # Valid for 1 year
}

# Assign a role to the service principal
resource "azurerm_role_assignment" "example" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.this.object_id
}

resource "azurerm_resource_group" "this" {
  name     = "${var.prefix}-resources"
  location = var.region
}

resource "azurerm_dns_zone" "this" {
  name                = var.domain_name
  resource_group_name = azurerm_resource_group.this.name
}

locals {
  output = [for ns in azurerm_dns_zone.this.name_servers : ns]
}

resource "null_resource" "pause_to_get_nameservers" {
  depends_on = [ azurerm_dns_zone.this ]

  provisioner "local-exec" {
    when = create
    command = "echo '#######NAMESERVERS:' && echo \"${join(", ", local.output)}\" && echo '#######'"
  }
  triggers = {
    always_run = "${timestamp()}"
  }
}

resource "azurerm_role_assignment" "dns_contributor" {
  principal_id         = data.azurerm_client_config.current.object_id
  role_definition_name = "DNS Zone Contributor"
  scope                = azurerm_resource_group.this.id
}

# Azure Container Registry
resource "azurerm_container_registry" "this" {
  name                = "${var.prefix}acr"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = true
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-network"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "public" {
  name                 = "public-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "private" {
  name                 = "private-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "containerinstance"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action", "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action"]
    }
  }
}

locals {
  parsed_credentials = jsondecode(azurerm_key_vault_secret.cosmosdb_credentials.value)
}

resource "azurerm_container_group" "this" {
  name                = "${var.prefix}-containergroup"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = "Linux"
  subnet_ids          = [azurerm_subnet.private.id]

  image_registry_credential {
    server   = azurerm_container_registry.this.login_server
    username = azurerm_container_registry.this.admin_username
    password = azurerm_container_registry.this.admin_password
  }

  container {
    name   = "${var.prefix}-container"
    image  = "${azurerm_container_registry.this.login_server}/${var.prefix}acr:v1"
    cpu    = "0.5"
    memory = "1.5"

    environment_variables = {
      COSMOSDB_USERNAME          = local.parsed_credentials["username"],
      COSMOSDB_PASSWORD          = local.parsed_credentials["password"],
      COSMOSDB_ENDPOINT          = local.parsed_credentials["endpoint"],
      COSMOSDB_DATABASE          = local.parsed_credentials["database"],
      COSMOSDB_CONNECTION_STRING = local.parsed_credentials["connection_string"],
      NODEPORT                   = "5000"
    }

    ports {
      port     = 5000
      protocol = "TCP"
    }
  }

  ip_address_type = "Private"
  depends_on = [
    azurerm_cosmosdb_account.this,
    acme_certificate.cert,
    azurerm_container_registry.this,
    github_repository_file.backend_workflow
  ]
}

resource "azurerm_public_ip" "this" {
  name                = "${var.prefix}-publicip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "this" {
  name                = "${var.prefix}-appgateway"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20170401S"
  }

  probe {
    name                = "aci-health-probe"
    protocol            = "Http"
    path                = "/health"
    port                = 5000
    host                = azurerm_container_group.this.ip_address
    interval            = 30 # Time interval between probes in seconds
    timeout             = 30 # Timeout for the probe in seconds
    unhealthy_threshold = 3  # Number of consecutive failures before marking as unhealthy
  }


  gateway_ip_configuration {
    name      = "${var.prefix}-gateway-ip-configuration"
    subnet_id = azurerm_subnet.public.id
  }

  frontend_port {
    name = "frontend-port-https"
    port = 443
  }

  ssl_certificate {
    name     = "${var.prefix}-domain-certificate"
    data     = azurerm_key_vault_certificate.import.certificate.0.contents
    password = ""
  }

  frontend_ip_configuration {
    name                 = "frontend-ip-configuration"
    public_ip_address_id = azurerm_public_ip.this.id
  }

  backend_address_pool {
    name  = "backend-address-pool"
    fqdns = [azurerm_container_group.this.ip_address]
  }

  backend_http_settings {
    name                  = "backend-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 5000
    protocol              = "Http"
    request_timeout       = 60
    probe_name            = "aci-health-probe"
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "frontend-ip-configuration"
    frontend_port_name             = "frontend-port-https"
    protocol                       = "Https"
    ssl_certificate_name           = "${var.prefix}-domain-certificate"
  }

  request_routing_rule {
    name                       = "https-request-routing-rule"
    priority                   = 1
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "backend-address-pool"
    backend_http_settings_name = "backend-http-settings"
  }
}

resource "azurerm_network_security_group" "this" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "allow_appgateway_to_aci"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow_appgateway_v2_ports"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow_all_outbound"
    priority                   = 1003
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Associate NSG with public subnet
resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.this.id
}

# Associate NSG with private subnet
resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.this.id
}


resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.prefix}-workspace"
  location            = "East US"
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = "${var.prefix}-diagnostics"
  target_resource_id         = azurerm_application_gateway.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "ApplicationGatewayAccessLog"
  }

  enabled_log {
    category = "ApplicationGatewayPerformanceLog"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

resource "random_pet" "this" {
  length    = 2
  separator = "-"
}

resource "azurerm_key_vault" "this" {
  name                = "${var.prefix}-kv"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    certificate_permissions = [
      "Get", "List", "Delete", "Create", "Import", "Update", "ManageContacts", "GetIssuers", "ListIssuers", "SetIssuers", "DeleteIssuers", "ManageIssuers", "Recover", "Backup", "Restore", "Purge"
    ]

    key_permissions = [
      "Get", "List", "Delete", "Create", "Import", "Update", "Recover", "Backup", "Restore", "Purge"
    ]

    secret_permissions = [
      "Get", "List", "Delete", "Set", "Recover", "Backup", "Restore", "Purge"
    ]
  }
}

resource "azurerm_key_vault_secret" "api_key" {
  name         = "deployment-secret"
  value        = azurerm_static_site.this.api_key
  key_vault_id = azurerm_key_vault.this.id
}

resource "azurerm_key_vault_secret" "client_app_service" {
  name         = "client-secret"
  value        = azuread_application_password.this.value
  key_vault_id = azurerm_key_vault.this.id
}

resource "tls_private_key" "private_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "acme_registration" "reg" {
  account_key_pem = tls_private_key.private_key.private_key_pem
  email_address   = var.email_address
}

resource "azurerm_dns_txt_record" "this" {
  name                = "_acme-challenge"
  zone_name           = azurerm_dns_zone.this.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 120
  record {
    value = acme_registration.reg.registration_url
  }
}

data "external" "dns_check" {
  depends_on = [azurerm_dns_txt_record.this]

  program = ["./scripts/check_dns_propagation.sh", "_acme-challenge.${var.domain_name}", acme_registration.reg.registration_url, "TXT"]
}

resource "acme_certificate" "cert" {
  depends_on = [
    azurerm_dns_zone.this,
    azurerm_dns_a_record.this,
    acme_registration.reg,
    azurerm_dns_cname_record.this,
    data.external.dns_check
  ]

  account_key_pem           = acme_registration.reg.account_key_pem
  common_name               = var.domain_name
  subject_alternative_names = ["${var.subdomain}.${var.domain_name}", "${var.domain_name}", "frontend.${var.domain_name}"]

  dns_challenge {
    provider = "azure"
    config = {
      AZURE_RESOURCE_GROUP  = azurerm_resource_group.this.name
      AZURE_CLIENT_ID       = azuread_application.this.application_id
      AZURE_CLIENT_SECRET   = azuread_application_password.this.value
      AZURE_SUBSCRIPTION_ID = data.azurerm_client_config.current.subscription_id
      AZURE_TENANT_ID       = data.azuread_client_config.current.tenant_id

    }
  }
}

resource "azurerm_key_vault_certificate" "import" {
  name         = "${var.prefix}-domain-certificate"
  key_vault_id = azurerm_key_vault.this.id

  certificate {
    contents = acme_certificate.cert.certificate_p12
    password = acme_certificate.cert.certificate_p12_password
  }

  certificate_policy {
    issuer_parameters {
      name = "Unknown"
    }

    key_properties {
      exportable = true
      key_type   = "RSA"
      reuse_key  = true
      key_size   = 2048
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=${var.domain_name}"
      validity_in_months = 12
      key_usage = [
        "cRLSign",
        "dataEncipherment",
        "digitalSignature",
        "keyEncipherment",
        "keyAgreement",
        "keyCertSign"
      ]
    }
  }
}

resource "azurerm_dns_a_record" "this" {
  name                = "@" # "@" denotes the root domain
  zone_name           = azurerm_dns_zone.this.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  records             = [azurerm_public_ip.this.ip_address]
}

resource "azurerm_cosmosdb_account" "this" {
  name                = "${var.prefix}-cosmosdb"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  offer_type          = "Standard"
  kind                = "MongoDB"

  consistency_policy {
    consistency_level       = "Session"
    max_interval_in_seconds = 10
    max_staleness_prefix    = 200
  }

  geo_location {
    location          = azurerm_resource_group.this.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_mongo_database" "this" {
  name                = "${var.prefix}-mongo-db"
  resource_group_name = azurerm_resource_group.this.name
  account_name        = azurerm_cosmosdb_account.this.name
}

locals {
  cosmosdb_credentials = jsonencode({
    endpoint          = azurerm_cosmosdb_account.this.endpoint,
    username          = azurerm_cosmosdb_account.this.name,
    password          = azurerm_cosmosdb_account.this.primary_key,
    database          = azurerm_cosmosdb_mongo_database.this.name,
    connection_string = azurerm_cosmosdb_account.this.connection_strings[0]
  })
}

resource "azurerm_key_vault_secret" "cosmosdb_credentials" {
  name         = "${var.prefix}-cosmosdb-credentials"
  value        = local.cosmosdb_credentials
  key_vault_id = azurerm_key_vault.this.id
}

data "external" "dns_cname_check" {
  depends_on = [azurerm_dns_cname_record.this]

  program = ["./scripts/check_dns_propagation.sh", "www.${var.domain_name}", "${azurerm_static_site.this.default_host_name}.", "CNAME"]
}

resource "azurerm_static_site" "this" {
  name                = "${var.prefix}-static-site"
  location            = "eastus2"
  resource_group_name = azurerm_resource_group.this.name
  sku_size            = "Standard"
  sku_tier            = "Free"
}

resource "azurerm_dns_cname_record" "this" {
  depends_on          = [azurerm_dns_zone.this]
  name                = var.subdomain
  zone_name           = var.domain_name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  record              = azurerm_static_site.this.default_host_name
}

resource "azurerm_static_site_custom_domain" "this" {
  static_site_id  = azurerm_static_site.this.id
  domain_name     = "${azurerm_dns_cname_record.this.name}.${azurerm_dns_cname_record.this.zone_name}"
  validation_type = "cname-delegation"
  depends_on = [ data.external.dns_cname_check ]
}

data "github_user" "current" {
  username = var.github_username
}

provider "github" {
  alias = "owner"
  owner = var.github_username
  token = var.github_token
}

data "github_actions_public_key" "backend_public_key" {
  repository = var.repository_name_backend
}

data "github_actions_public_key" "frontend_public_key" {
  repository = var.repository_name_frontend
}

resource "github_actions_secret" "deployment_secret" {
  repository      = var.repository_name_frontend
  secret_name     = "DEPLOYMENT_SECRET"
  plaintext_value = azurerm_key_vault_secret.api_key.value
  provider        = github.owner
}

resource "github_actions_secret" "acr_username" {
  repository      = var.repository_name_backend
  secret_name     = "ACR_USERNAME"
  plaintext_value = azurerm_container_registry.this.admin_username
  provider        = github.owner
}

resource "github_actions_secret" "acr_password" {
  repository      = var.repository_name_backend
  secret_name     = "ACR_PASSWORD"
  plaintext_value = azurerm_container_registry.this.admin_password
  provider        = github.owner
}

resource "github_repository_file" "frontend_workflow" {
  depends_on = [azurerm_key_vault_secret.api_key, azurerm_static_site.this, github_actions_secret.deployment_secret]

  overwrite_on_create = true
  repository          = var.repository_name_frontend
  file                = ".github/workflows/frontend.yml"
  content             = <<-EOF
    name: CI/CD Pipeline

    on:
      push:
        branches:
          - main

    jobs:
      build:
        runs-on: ubuntu-latest

        steps:
        - name: Checkout code
          uses: actions/checkout@v3

        - name: Set up Node.js
          uses: actions/setup-node@v3
          with:
            node-version: '18'

        - name: Install dependencies
          run: yarn install

        - name: Build
          run: yarn build

        - name: Create config.json
          run: |
            echo '{
              "REACT_APP_BACKEND_URL": "${var.domain_name}"
            }' > build/config.json

        - name: Deploy to Azure Static Web App
          uses: azure/static-web-apps-deploy@v1
          with:
              azure_static_web_apps_api_token: $${{ secrets.DEPLOYMENT_SECRET }}
              action: "upload"
              app_location: "build"
    EOF
}

resource "github_repository_file" "backend_workflow" {
  depends_on = [azurerm_container_registry.this,
    github_actions_secret.acr_username,
    github_actions_secret.acr_password
  ]

  overwrite_on_create = true
  repository          = var.repository_name_backend
  branch              = "azure"
  file                = ".github/workflows/backend.yml"
  content             = <<-EOT
    name: Push Docker image to custom registry

    on:
      push:
        branches:
          - azure

    jobs:
      push_to_registry:
        name: Build and push Docker image
        runs-on: ubuntu-latest
        steps:
          - name: Check out the repo
            uses: actions/checkout@v2

          - name: Log in to Docker registry
            uses: azure/docker-login@v1
            with:
              login-server: ${azurerm_container_registry.this.login_server}
              username: $${{ secrets.ACR_USERNAME }}
              password: $${{ secrets.ACR_PASSWORD }}

          - name: Build and push Docker image
            uses: docker/build-push-action@v2
            with:
              context: .
              file: ./Dockerfile
              push: true
              tags: ${azurerm_container_registry.this.login_server}/${var.prefix}acr:v1
      EOT
}

data "http" "dispatch_event_backend" {
  url    = "https://api.github.com/repos/${var.github_username}/${var.repository_name_backend}/dispatches"
  method = "POST"

  request_headers = {
    Accept        = "application/vnd.github.everest-preview+json"
    Authorization = "token ${var.github_token}"
  }

  request_body = jsonencode({
    event_type = "my-event"
  })

  depends_on = [github_repository_file.backend_workflow]
}

data "http" "dispatch_event_frontend" {
  url    = "https://api.github.com/repos/${var.github_username}/${var.repository_name_frontend}/dispatches"
  method = "POST"

  request_headers = {
    Accept        = "application/vnd.github.everest-preview+json"
    Authorization = "token ${var.github_token}"
  }

  request_body = jsonencode({
    event_type = "my-event"
  })

  depends_on = [github_repository_file.frontend_workflow]
}
