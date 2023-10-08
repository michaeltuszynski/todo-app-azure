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
  description = "Github Backend Repository Name"
  type        = string
}

variable "repository_name_frontend" {
  description = "Github Frontend Repository Name"
  type        = string
}
