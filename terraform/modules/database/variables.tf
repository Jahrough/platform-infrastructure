variable "cluster_name" {
  description = "Prefix used for database parameter-group naming."
  type        = string
}

variable "vpc_id" {
  description = "VPC in which the private database is provisioned."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the database subnet group."
  type        = list(string)
}

variable "eks_node_security_group" {
  description = "EKS node security group permitted to connect to PostgreSQL."
  type        = string
}
