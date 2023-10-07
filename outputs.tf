output "nameservers_list" {
  value = [for ns in azurerm_dns_zone.this.name_servers : ns]
}

output "dns_check_result" {
  description = "The result of the DNS check"
  value       = data.external.dns_check.result
}