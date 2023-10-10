data "azurerm_client_config" "current" {}

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

resource "azurerm_key_vault_secret" "client_app_service" {
  name         = "client-secret"
  value        = azuread_application_password.this.value
  key_vault_id = azurerm_key_vault.this.id
}

resource "azurerm_key_vault_secret" "client_id" {
  name         = "client-id"
  value        = azuread_application.this.application_id
  key_vault_id = azurerm_key_vault.this.id
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

resource "azurerm_public_ip" "this" {
  name                = "${var.prefix}-publicip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_dns_a_record" "this" {
  name                = "@" # "@" denotes the root domain
  zone_name           = azurerm_dns_zone.this.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  records             = [azurerm_public_ip.this.ip_address]
}
