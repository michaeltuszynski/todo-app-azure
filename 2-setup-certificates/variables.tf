variable "prefix" {
  description = "Prefix for all resources"
  type        = string
}

variable "email_address" {
  description = "Email Address"
  type        = string
}

variable "key_vault" {
  description = "Azure Key Vault Name"
  type        = string
}

variable "resource_group" {
  description = "Azure Resource Group Name"
  type        = string
}

variable "zone_name" {
  description = "Azure DNS Zone Name"
  type        = string
}

variable "subdomain" {
  description = "Subdomain"
  type        = string
}