terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.74.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

provider "acme" {
  server_url = "https://acme-v02.api.letsencrypt.org/directory"
}