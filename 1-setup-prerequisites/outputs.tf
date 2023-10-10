output "nameservers_list" {
  value = [for ns in azurerm_dns_zone.this.name_servers : ns]
}

output "grouped_outputs" {
  value = {
    resource_group = azurerm_resource_group.this.name
    key_vault      = azurerm_key_vault.this.name
    acr            = azurerm_container_registry.this.name
    network = {
      name           = azurerm_virtual_network.this.name
      public_subnet  = azurerm_subnet.public.name
      private_subnet = azurerm_subnet.private.name
    }
    zone_name      = azurerm_dns_zone.this.name
  }
}
