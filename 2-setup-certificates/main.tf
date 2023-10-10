data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}

data "azurerm_resource_group" "this" {
  name = var.resource_group
}

data "azurerm_dns_zone" "this" {
  name                = var.zone_name
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_dns_a_record" "this" {
  name                = "@"
  zone_name           = data.azurerm_dns_zone.this.name
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_key_vault_secret" "client_id" {
  name         = "client-id"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "client_secret" {
  name         = "client-secret"
  key_vault_id = data.azurerm_key_vault.this.id
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
  zone_name           = data.azurerm_dns_zone.this.name
  resource_group_name = data.azurerm_resource_group.this.name
  ttl                 = 120
  record {
    value = acme_registration.reg.registration_url
  }
}

data "external" "dns_check" {
  depends_on = [azurerm_dns_txt_record.this]
  program    = ["./scripts/check_dns_propagation.sh", "_acme-challenge.${data.azurerm_dns_zone.this.name}", acme_registration.reg.registration_url, "TXT"]
}

resource "acme_certificate" "cert" {
  depends_on = [
    data.azurerm_dns_zone.this,
    data.azurerm_dns_a_record.this,
    acme_registration.reg,
    data.external.dns_check
  ]

  account_key_pem           = acme_registration.reg.account_key_pem
  common_name               = data.azurerm_dns_zone.this.name
  subject_alternative_names = ["${data.azurerm_dns_zone.this.name}", "*.${data.azurerm_dns_zone.this.name}"]

  dns_challenge {
    provider = "azure"
    config = {
      AZURE_RESOURCE_GROUP = data.azurerm_resource_group.this.name
      #AZURE_CLIENT_ID       = var.application_id
      AZURE_CLIENT_ID       = data.azurerm_key_vault_secret.client_id.value
      AZURE_CLIENT_SECRET   = data.azurerm_key_vault_secret.client_secret.value
      AZURE_SUBSCRIPTION_ID = data.azurerm_client_config.current.subscription_id
      AZURE_TENANT_ID       = data.azuread_client_config.current.tenant_id

    }
  }
}

resource "azurerm_key_vault_certificate" "domain_certificate" {
  name         = "${var.prefix}-domain-certificate"
  key_vault_id = data.azurerm_key_vault.this.id

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
      subject            = "CN=${data.azurerm_dns_zone.this.name}"
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


