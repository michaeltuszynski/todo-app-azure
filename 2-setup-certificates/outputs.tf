output "acme_cert" {
  value = acme_certificate.cert.common_name
}

output "key_vault_certificate" {
  value = azurerm_key_vault_certificate.domain_certificate.id
}
