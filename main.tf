resource "azurerm_resource_group" "example" {
  name     = "example-resources"
  location = "East US"
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

    ports {
      port     = 5000
      protocol = "TCP"
    }
  }

  tags = {
    environment = "testing"
  }

  ip_address_type = "Private"

  depends_on = [null_resource.push_image]
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

  probe {
    name                = "aci-health-probe"
    protocol            = "Http"
    path                = "/"
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
    name = "frontend-port"
    port = 80
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

  http_listener {
    name                           = "http-listener"
    protocol                       = "Http"
    frontend_ip_configuration_name = "frontend-ip-configuration"
    frontend_port_name             = "frontend-port"
  }

  request_routing_rule {
    name                       = "http-request-routing-rule"
    priority                   = 1
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
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
    destination_port_range     = "80"
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




output "public_ip_address" {
  value = azurerm_public_ip.example.ip_address
}
