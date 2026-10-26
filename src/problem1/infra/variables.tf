variable "account_id" {
  type    = string
  default = "730335245469"
  validation {
    condition     = var.account_id == "730335245469"
    error_message = "This checkout is dedicated to sandbox account 730335245469."
  }
}
variable "aws_profile" {
  type    = string
  default = "AWSAdministratorAccess-730335245469"
}
variable "region" {
  type    = string
  default = "ap-southeast-1"
}
variable "prefix" {
  type    = string
  default = "dom7hc-practice"
  validation {
    condition     = var.prefix == "dom7hc-practice"
    error_message = "This deployment is scoped to dom7hc-practice."
  }
}
variable "running" {
  type    = bool
  default = true
}
variable "image_tag" {
  type    = string
  default = "v6"
}
