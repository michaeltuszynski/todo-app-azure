data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "example" {
  name     = "example-resources"
  location = "East US"
}

resource "azurerm_role_assignment" "dns_contributor" {
  principal_id = "ecf3e49e-4cbf-4eba-aa8a-eaf6cbc424e4"
  #principal_id = data.azurerm_client_config.current.object_id   ##TODO FIX THIS
  role_definition_name = "DNS Zone Contributor"
  scope                = azurerm_resource_group.example.id
}

# Azure Container Registry
resource "azurerm_container_registry" "this" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.example.name
  location            = azurerm_resource_group.example.location
  sku                 = "Basic"
  admin_enabled       = true
}

resource "null_resource" "push_image" {
  provisioner "local-exec" {
    command = <<EOT
      docker login ${azurerm_container_registry.this.login_server} -u ${azurerm_container_registry.this.admin_username} -p ${azurerm_container_registry.this.admin_password}
      docker tag ${var.acr_name}:latest ${azurerm_container_registry.this.login_server}/${var.acr_name}:v1
      docker push ${azurerm_container_registry.this.login_server}/${var.acr_name}:v1
    EOT
  }

  triggers = {
    always_run = "${timestamp()}"
  }
}


resource "azurerm_virtual_network" "example" {
  name                = "example-network"
  resource_group_name = azurerm_resource_group.example.name
  location            = azurerm_resource_group.example.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "public" {
  name                 = "public-subnet"
  resource_group_name  = azurerm_resource_group.example.name
  virtual_network_name = azurerm_virtual_network.example.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "private" {
  name                 = "private-subnet"
  resource_group_name  = azurerm_resource_group.example.name
  virtual_network_name = azurerm_virtual_network.example.name
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

resource "azurerm_container_group" "example" {
  name                = "example-containergroup"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  os_type             = "Linux"
  subnet_ids          = [azurerm_subnet.private.id]

  image_registry_credential {
    server   = azurerm_container_registry.this.login_server
    username = azurerm_container_registry.this.admin_username
    password = azurerm_container_registry.this.admin_password
  }

  container {
    name   = "example-container"
    image  = "${azurerm_container_registry.this.login_server}/${var.acr_name}:v1"
    cpu    = "0.5"
    memory = "1.5"

    environment_variables = {
      COSMOSDB_USERNAME = local.parsed_credentials["username"],
      COSMOSDB_PASSWORD = local.parsed_credentials["password"],
      COSMOSDB_ENDPOINT  = local.parsed_credentials["endpoint"],
      COSMOSDB_DATABASE = local.parsed_credentials["database"],
      COSMOSDB_CONNECTION_STRING = local.parsed_credentials["connection_string"],
      NODEPORT = "5000"
    }

    ports {
      port     = 5000
      protocol = "TCP"
    }
  }

  tags = {
    environment = "testing"
  }

  ip_address_type = "Private"

  depends_on = [null_resource.push_image, azurerm_cosmosdb_account.example]
}

resource "azurerm_public_ip" "example" {
  name                = "example-publicip"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "example" {
  name                = "example-appgateway"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name

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
    host                = azurerm_container_group.example.ip_address
    interval            = 30 # Time interval between probes in seconds
    timeout             = 30 # Timeout for the probe in seconds
    unhealthy_threshold = 3  # Number of consecutive failures before marking as unhealthy
  }


  gateway_ip_configuration {
    name      = "my-gateway-ip-configuration"
    subnet_id = azurerm_subnet.public.id
  }

  frontend_port {
    name = "frontend-port-https"
    #port = 80
    port = 443
  }

  ssl_certificate {
    name     = "miketuszynski-info-certificate"
    data     = azurerm_key_vault_certificate.import.certificate.0.contents
    password = ""
  }

  frontend_ip_configuration {
    name                 = "frontend-ip-configuration"
    public_ip_address_id = azurerm_public_ip.example.id
  }

  backend_address_pool {
    name  = "backend-address-pool"
    fqdns = [azurerm_container_group.example.ip_address]
  }

  backend_http_settings {
    name                  = "backend-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 5000
    protocol              = "Http"
    request_timeout       = 60
    probe_name            = "aci-health-probe"
  }

  # http_listener {
  #   name                           = "http-listener"
  #   protocol                       = "Http"
  #   frontend_ip_configuration_name = "frontend-ip-configuration"
  #   frontend_port_name             = "frontend-port-http"
  # }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "frontend-ip-configuration"
    frontend_port_name             = "frontend-port-https"
    protocol                       = "Https"
    ssl_certificate_name           = "miketuszynski-info-certificate"
  }

  # request_routing_rule {
  #   name                       = "http-request-routing-rule"
  #   priority                   = 1
  #   rule_type                  = "Basic"
  #   http_listener_name         = "http-listener"
  #   backend_address_pool_name  = "backend-address-pool"
  #   backend_http_settings_name = "backend-http-settings"
  # }

  request_routing_rule {
    name                       = "https-request-routing-rule"
    priority                   = 1
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "backend-address-pool"
    backend_http_settings_name = "backend-http-settings"
  }
}

resource "azurerm_network_security_group" "example" {
  name                = "example-nsg"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name

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
  network_security_group_id = azurerm_network_security_group.example.id
}

# Associate NSG with private subnet
resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.example.id
}


resource "azurerm_log_analytics_workspace" "example" {
  name                = "example-workspace"
  location            = "East US"
  resource_group_name = azurerm_resource_group.example.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_monitor_diagnostic_setting" "example" {
  name                       = "example-diagnostics"
  target_resource_id         = azurerm_application_gateway.example.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.example.id

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

resource "random_pet" "example" {
  length    = 2
  separator = "-"
}

resource "azurerm_key_vault" "example" {
  name                = "keyvault-${random_pet.example.id}"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
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

  tags = {
    environment = "testing"
  }
}

resource "tls_private_key" "private_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "acme_registration" "reg" {
  account_key_pem = tls_private_key.private_key.private_key_pem
  email_address   = "miketuszynski42@gmail.com"
}

resource "acme_certificate" "cert" {
  account_key_pem           = acme_registration.reg.account_key_pem
  common_name               = "miketuszynski.info"
  subject_alternative_names = ["www.miketuszynski.info"]

  dns_challenge {
    provider = "azure"
    config = {
      AZURE_CLIENT_ID       = var.client_id
      AZURE_CLIENT_SECRET   = var.client_secret
      AZURE_SUBSCRIPTION_ID = var.subscription_id
      AZURE_TENANT_ID       = var.tenant_id
      AZURE_RESOURCE_GROUP  = azurerm_resource_group.example.name
    }
  }
}

resource "azurerm_key_vault_certificate" "import" {
  name         = "miketuszynski-info-certificate"
  key_vault_id = azurerm_key_vault.example.id

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
      subject            = "CN=miketuszynski.info"
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

data "azurerm_dns_zone" "example" {
  name                = "miketuszynski.info"
  resource_group_name = azurerm_resource_group.example.name
}


resource "azurerm_dns_a_record" "example" {
  name                = "@" # "@" denotes the root domain
  zone_name           = data.azurerm_dns_zone.example.name
  resource_group_name = azurerm_resource_group.example.name
  ttl                 = 300
  records             = [azurerm_public_ip.example.ip_address]
}

resource "azurerm_dns_a_record" "www" {
  name                = "www"
  zone_name           = data.azurerm_dns_zone.example.name
  resource_group_name = azurerm_resource_group.example.name
  ttl                 = 300
  records             = [azurerm_public_ip.example.ip_address]
}



resource "azurerm_cosmosdb_account" "example" {
  name                = "example-cosmosdb"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  offer_type          = "Standard"
  kind                = "MongoDB"

  consistency_policy {
    consistency_level       = "Session"
    max_interval_in_seconds = 10
    max_staleness_prefix    = 200
  }

  geo_location {
    location          = azurerm_resource_group.example.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_mongo_database" "example" {
  name                = "example-mongo-db"
  resource_group_name = azurerm_resource_group.example.name
  account_name        = azurerm_cosmosdb_account.example.name
}

locals {
  cosmosdb_credentials = jsonencode({
    endpoint          = azurerm_cosmosdb_account.example.endpoint,
    username          = azurerm_cosmosdb_account.example.name,
    password          = azurerm_cosmosdb_account.example.primary_key,
    database          = azurerm_cosmosdb_mongo_database.example.name,
    connection_string = azurerm_cosmosdb_account.example.connection_strings[0]
  })
}


resource "azurerm_key_vault_secret" "cosmosdb_credentials" {
  name         = "cosmosdb-credentials"
  value        = local.cosmosdb_credentials
  key_vault_id = azurerm_key_vault.example.id
}



