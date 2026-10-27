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

variable "alert_email" {
  description = "Optional email address for production infrastructure alarms."
  type        = string
  default     = null

  validation {
    condition = (
      var.alert_email == null ||
      trimspace(var.alert_email) == "" ||
      can(regex("^[^@ ]+@[^@ ]+\\.[^@ ]+$", var.alert_email))
    )
    error_message = "alert_email must be a valid email address when set."
  }
}