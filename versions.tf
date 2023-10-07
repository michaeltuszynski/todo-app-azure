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
    github = {
      source = "integrations/github"
    }
  }
}

provider "azurerm" {
  features {
    # resource_group {
    #   prevent_deletion_if_contains_resources = true
    # }
  }
}

provider "acme" {
  server_url = "https://acme-v02.api.letsencrypt.org/directory"
}

provider "azuread" {}

provider "github" {
  token = var.github_token
  owner = var.github_username
}