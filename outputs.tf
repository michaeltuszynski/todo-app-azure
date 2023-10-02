output "public_ip_address" {
  value = azurerm_public_ip.example.ip_address
}

# output "application_id" {
#   value = azuread_application.example.application_id
# }

# output "service_principal_id" {
#   value = azuread_service_principal.example.id
# }

# output "service_principal_password" {
#   value     = azuread_service_principal_password.example.value
#   sensitive = true
# }

