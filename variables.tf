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
  default     = "simplenodempt"
}
