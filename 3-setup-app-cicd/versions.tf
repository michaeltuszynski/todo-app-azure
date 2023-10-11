terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.74.0"
    }
    github = {
      source = "integrations/github"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

provider "github" {
  token = var.github_token
  owner = var.github_username
}