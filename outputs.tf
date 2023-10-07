output "nameservers_list" {
  value = [for ns in azurerm_dns_zone.this.name_servers : ns]
}