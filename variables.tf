variable "region" {
  description = "Azure infrastructure region"
  type        = string
  default     = "East US"
}

variable "app" {
  description = "Application that we want to deploy"
  type        = string
  default     = "myapp"
}

variable "env" {
  description = "Application env"
  type        = string
  default     = "production"
}

variable "location" {
  description = "Location short name "
  type        = string
  default     = "eastus"
}

variable "acr_name" {
  description = "Azure Container Registry Name"
  type        = string
  default     = "todoappmpt"
}

variable "prefix" {
  description = "Prefix for all resources"
  type        = string
  default     = "myapp"
}

variable "client_id" {
  description = "Azure Service Principal Client ID"
  type        = string
}

variable "client_secret" {
  description = "Azure Service Principal Client Secret"
  type        = string
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}
