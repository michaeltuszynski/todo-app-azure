variable "region" {
  description = "Azure infrastructure region"
  type        = string
  default     = "East US"
}

variable "prefix" {
  description = "Prefix for all resources"
  type        = string
}

variable "domain_name" {
  description = "value of domain name"
  type        = string
}

variable "subdomain" {
  description = "value of subdomain"
  type        = string
}