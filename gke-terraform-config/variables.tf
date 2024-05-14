variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "zones" {
  type    = list(string)
  default = ["europe-west1-b"]
}

variable "initial_node_count" {
  type = number
}

variable "max_node_count" {
  type = number
}

variable "service_account" {
  type = string
}
