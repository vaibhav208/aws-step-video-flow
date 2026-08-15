variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread public subnets across."
  type        = number
  default     = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}
