variable "prefix" {
  description = "Prefix for all resources"
  type        = string
}

variable "application_port" {
  description = "Application Port"
  type        = number
}

variable "virtual_network" {
  description = "Azure Virtual Network Name"
  type        = string
}

variable "public_subnet" {
  description = "Azure Virtual Network Public Subnet Name"
  type        = string
}

variable "private_subnet" {
  description = "Azure Virtual Network Private Subnet Name"
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

variable "public_ip_id" {
  description = "Azure Public IP Address Id"
  type        = string
}

variable "container_registry" {
  description = "Azure Container Registry Name"
  type        = string
}

variable "repository_name_backend" {
  description = "Github Backend Repository Name"
  type        = string
}

variable "repository_name_frontend" {
  description = "Github Frontend Repository Name"
  type        = string
}

variable "repository_branch_frontend" {
  description = "Github Frontend Repository Branch"
  type        = string
}

variable "repository_branch_backend" {
  description = "Github Backend Repository Branch"
  type        = string
}

variable "github_token" {
  description = "Github Token"
  type        = string
}

variable "github_username" {
  description = "Github Username"
  type        = string
}

variable "subdomain" {
  description = "Subdomain"
  type        = string
  default     = "www"
}

variable "zone_name" {
  description = "Zone Name"
  type        = string
}
