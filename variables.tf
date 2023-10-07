variable "region" {
  description = "Azure infrastructure region"
  type        = string
  default     = "East US"
}

variable "prefix" {
  description = "Prefix for all resources"
  type        = string
  default     = "todoapp"
}

# variable "client_id" {
#   description = "Azure Service Principal Client ID"
#   type        = string
# }

# variable "client_secret" {
#   description = "Azure Service Principal Client Secret"
#   type        = string
# }

# variable "subscription_id" {
#   description = "Azure Subscription ID"
#   type        = string
# }

# variable "tenant_id" {
#   description = "Azure Tenant ID"
#   type        = string
# }

# variable "object_id" {
#   description = "Azure Object ID"
#   type        = string
# }

variable "domain_name" {
  description = "value of domain name"
  type        = string
}

variable "subdomain" {
  description = "value of subdomain"
  type        = string
  default     = "www"
}

variable "github_token" {
  description = "Github Token"
  type        = string
}

variable "github_username" {
  description = "Github Username"
  type        = string
}

variable "email_address" {
  description = "Email Address"
  type        = string
}

variable "repository_name_backend" {
  description = "Github Repository Name"
  type        = string
}

variable "repository_name_frontend" {
  description = "Github Repository Name"
  type        = string
}
