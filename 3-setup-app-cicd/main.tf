data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}

data "azurerm_resource_group" "this" {
  name = var.resource_group
}

data "azurerm_user_assigned_identity" "this" {
  name                = "${var.prefix}-identity"
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_public_ip" "this" {
  name                = var.public_ip_id
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_dns_zone" "this" {
  name                = var.zone_name
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_key_vault_secret" "domain_certificate" {
  name         = "${var.prefix}-domain-certificate"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_subnet" "public" {
  name                 = var.public_subnet
  virtual_network_name = var.virtual_network
  resource_group_name  = data.azurerm_resource_group.this.name
}

data "azurerm_subnet" "private" {
  name                 = var.private_subnet
  virtual_network_name = var.virtual_network
  resource_group_name  = data.azurerm_resource_group.this.name
}

data "azurerm_container_registry" "this" {
  name                = var.container_registry
  resource_group_name = data.azurerm_resource_group.this.name
}

data "github_actions_public_key" "backend_public_key" {
  repository = var.repository_name_backend
}

data "github_actions_public_key" "frontend_public_key" {
  repository = var.repository_name_frontend
}

###### Database
resource "azurerm_cosmosdb_account" "this" {
  name                = "${var.prefix}-cosmosdb"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  offer_type          = "Standard"
  kind                = "MongoDB"

  consistency_policy {
    consistency_level       = "Session"
    max_interval_in_seconds = 10
    max_staleness_prefix    = 200
  }

  geo_location {
    location          = data.azurerm_resource_group.this.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_mongo_database" "this" {
  name                = "${var.prefix}-mongo-db"
  resource_group_name = data.azurerm_resource_group.this.name
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
  key_vault_id = data.azurerm_key_vault.this.id
}

###Container Account
locals {
  parsed_credentials = jsondecode(azurerm_key_vault_secret.cosmosdb_credentials.value)
}

resource "azurerm_container_group" "this" {
  name                = "${var.prefix}-containergroup"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  os_type             = "Linux"
  subnet_ids          = [data.azurerm_subnet.private.id]

  image_registry_credential {
    server   = data.azurerm_container_registry.this.login_server
    username = data.azurerm_container_registry.this.admin_username
    password = data.azurerm_container_registry.this.admin_password
  }

  container {
    name   = "${var.prefix}-container"
    image  = "${data.azurerm_container_registry.this.login_server}/${var.prefix}acr:v1"
    cpu    = "0.5"
    memory = "1.5"

    environment_variables = {
      COSMOSDB_USERNAME          = local.parsed_credentials["username"],
      COSMOSDB_PASSWORD          = local.parsed_credentials["password"],
      COSMOSDB_ENDPOINT          = local.parsed_credentials["endpoint"],
      COSMOSDB_DATABASE          = local.parsed_credentials["database"],
      COSMOSDB_CONNECTION_STRING = local.parsed_credentials["connection_string"],
      NODEPORT                   = "${var.application_port}"
      DOMAIN                     = "${var.subdomain}.${data.azurerm_dns_zone.this.name}"
    }

    ports {
      port     = var.application_port
      protocol = "TCP"
    }
  }

  ip_address_type = "Private"
  depends_on = [
    azurerm_cosmosdb_account.this,
    data.azurerm_container_registry.this,
    github_repository_file.backend_workflow
  ]
}

resource "azurerm_application_gateway" "this" {
  name                = "${var.prefix}-appgateway"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.this.id]
  }

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20170401S"
  }

  probe {
    name                = "aci-health-probe"
    protocol            = "Http"
    path                = "/health"
    port                = var.application_port
    host                = azurerm_container_group.this.ip_address
    interval            = 30 # Time interval between probes in seconds
    timeout             = 30 # Timeout for the probe in seconds
    unhealthy_threshold = 3  # Number of consecutive failures before marking as unhealthy
  }


  gateway_ip_configuration {
    name      = "${var.prefix}-gateway-ip-configuration"
    subnet_id = data.azurerm_subnet.public.id
  }

  frontend_port {
    name = "frontend-port-https"
    port = 443
  }

  ssl_certificate {
    name                = "${var.prefix}-domain-certificate"
    key_vault_secret_id = data.azurerm_key_vault_secret.domain_certificate.id
  }

  frontend_ip_configuration {
    name                 = "frontend-ip-configuration"
    public_ip_address_id = data.azurerm_public_ip.this.id
  }

  backend_address_pool {
    name  = "backend-address-pool"
    fqdns = [azurerm_container_group.this.ip_address]
  }

  backend_http_settings {
    name                  = "backend-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = var.application_port
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

##Frontend Static Site
resource "azurerm_static_site" "this" {
  name                = "${var.prefix}-static-site"
  location            = "eastus2"
  resource_group_name = data.azurerm_resource_group.this.name
  sku_size            = "Standard"
  sku_tier            = "Free"
}

resource "azurerm_dns_cname_record" "this" {
  depends_on          = [data.azurerm_dns_zone.this]
  name                = var.subdomain
  zone_name           = data.azurerm_dns_zone.this.name
  resource_group_name = data.azurerm_resource_group.this.name
  ttl                 = 300
  record              = azurerm_static_site.this.default_host_name
}

resource "azurerm_static_site_custom_domain" "this" {
  static_site_id  = azurerm_static_site.this.id
  domain_name     = "${azurerm_dns_cname_record.this.name}.${azurerm_dns_cname_record.this.zone_name}"
  validation_type = "cname-delegation"
  depends_on      = [data.external.dns_cname_check]
}

resource "azurerm_key_vault_secret" "deployment_secret" {
  name         = "deployment-secret"
  value        = azurerm_static_site.this.api_key
  key_vault_id = data.azurerm_key_vault.this.id
}

data "external" "dns_cname_check" {
  depends_on = [azurerm_dns_cname_record.this]
  program    = ["./scripts/check_dns_propagation.sh", "www.${data.azurerm_dns_zone.this.name}", "${azurerm_static_site.this.default_host_name}.", "CNAME"]
}


##Github Actions CI/CD
resource "github_actions_secret" "deployment_secret" {
  repository      = var.repository_name_frontend
  secret_name     = "DEPLOYMENT_SECRET"
  plaintext_value = azurerm_key_vault_secret.deployment_secret.value
}

resource "github_actions_secret" "acr_username" {
  repository      = var.repository_name_backend
  secret_name     = "ACR_USERNAME"
  plaintext_value = data.azurerm_container_registry.this.admin_username
}

resource "github_actions_secret" "acr_password" {
  repository      = var.repository_name_backend
  secret_name     = "ACR_PASSWORD"
  plaintext_value = data.azurerm_container_registry.this.admin_password
}

resource "github_repository_file" "frontend_workflow" {
  depends_on = [azurerm_static_site.this, github_actions_secret.deployment_secret]

  overwrite_on_create = true
  repository          = var.repository_name_frontend
  branch              = var.repository_branch_frontend
  file                = ".github/workflows/frontend.yml"
  content             = templatefile("yml/frontend-azure-cicd.yml", {
    azure_branch = var.repository_branch_frontend
    azure_service = data.azurerm_dns_zone.this.name
  })
}

resource "github_repository_file" "backend_workflow" {
  depends_on = [data.azurerm_container_registry.this,
    github_actions_secret.acr_username,
    github_actions_secret.acr_password
  ]

  overwrite_on_create = true
  repository          = var.repository_name_backend
  branch              = var.repository_branch_backend
  file                = ".github/workflows/backend.yml"
  content             = templatefile("yml/backend-azure-cicd.yml", {
    azure_branch = var.repository_branch_backend
    azure_registry = data.azurerm_container_registry.this.login_server
    azure_image = "${data.azurerm_container_registry.this.login_server}/${var.prefix}acr:v1"
  })
}

data "http" "dispatch_event_backend" {
  url    = "https://api.github.com/repos/${var.github_username}/${var.repository_name_backend}/dispatches"
  method = "POST"

  request_headers = {
    Accept        = "application/vnd.github.everest-preview+json"
    Authorization = "token ${var.github_token}"
  }

  request_body = jsonencode({
    event_type = "start-event"
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
    event_type = "start-event"
  })

  depends_on = [github_repository_file.frontend_workflow]
}

