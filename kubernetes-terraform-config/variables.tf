variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "namedotcom_username" {
  type = string
}

variable "namedotcom_token" {
  type = string
}

variable "idp_domain_name" {
  type        = string
  description = "The domain name (e.g. code.berlin)"
}

variable "idp_domain_host" {
  type        = string
  description = "The Subdomain, needs to be a wildcard (e.g. '*.idp' which means test.idp.code.berlin is a valid domain)"
  default     = "*.idp"
}

variable "certificate_issuer_email" {
  type        = string
  description = "This is the email that is used to create the LetsEncrypt certificate"
}

