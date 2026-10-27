variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "product-catalog-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version supported by EKS in the selected AWS region."
  type        = string
}

variable "db_password" {
  description = "PostgreSQL master password. Supply it through a secure CI secret or TF_VAR_db_password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 16 && length(var.db_password) <= 128
    error_message = "db_password must be between 16 and 128 characters."
  }
}