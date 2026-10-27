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

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.cluster_version))
    error_message = "cluster_version must be a Kubernetes minor version such as 1.33."
  }
}

variable "alert_email" {
  description = "Email address for production infrastructure alarm notifications."
  type        = string

  validation {
    condition     = can(regex("^[^@ ]+@[^@ ]+\\.[^@ ]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}