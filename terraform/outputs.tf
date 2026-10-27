output "eks_cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_name" {
  description = "EKS cluster name used by Kubernetes controllers."
  value       = module.eks.cluster_name
}

output "aws_region" {
  description = "AWS region used by the platform and Kubernetes secret provider."
  value       = var.aws_region
}

output "cluster_name" {
  description = "Terraform cluster-name prefix used by AWS Secrets Manager."
  value       = var.cluster_name
}

output "vpc_id" {
  description = "VPC ID used to configure AWS load balancer controller."
  value       = module.vpc.vpc_id
}

output "rds_endpoint" {
  description = "RDS PostgreSQL instance connection endpoint"
  value       = aws_db_instance.postgres.endpoint
}

output "rds_master_secret_arn" {
  description = "AWS-managed RDS master credential secret ARN; do not use it as an application credential."
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "kafka_bootstrap_tls" {
  description = "Private TLS bootstrap endpoints for the MSK cluster."
  value       = aws_msk_cluster.platform.bootstrap_brokers_tls
}

output "redis_primary_endpoint" {
  description = "Private primary endpoint for the encrypted Redis replication group."
  value       = aws_elasticache_replication_group.platform.primary_endpoint_address
}

output "redis_auth_secret_arn" {
  description = "Secrets Manager ARN for the Redis AUTH token."
  value       = aws_secretsmanager_secret.redis_auth.arn
}

output "opensearch_endpoint" {
  description = "Private HTTPS endpoint for OpenSearch."
  value       = "https://${aws_opensearch_domain.platform.endpoint}"
}

output "runtime_config_secret_arn" {
  description = "Secrets Manager secret containing the managed service endpoints used by External Secrets."
  value       = aws_secretsmanager_secret.runtime_config.arn
}

output "app_database_secret_name" {
  description = "Create this Secrets Manager secret value with JSON keys username and password after provisioning the product-catalog DB account."
  value       = aws_secretsmanager_secret.app_db.name
}

output "search_database_secret_name" {
  description = "Create this Secrets Manager secret value with JSON keys url, username, and password after provisioning the product-search DB account."
  value       = aws_secretsmanager_secret.search_db.name
}

output "cdc_database_secret_name" {
  description = "Create this Secrets Manager secret value with JSON keys username and password after provisioning the PostgreSQL replication account."
  value       = aws_secretsmanager_secret.cdc_db.name
}

output "external_secrets_irsa_role_arn" {
  description = "IAM role ARN to annotate the External Secrets Operator service account with."
  value       = aws_iam_role.external_secrets.arn
}

output "load_balancer_controller_irsa_role_arn" {
  description = "IAM role ARN to set in the AWS Load Balancer Controller Argo CD application."
  value       = aws_iam_role.load_balancer_controller.arn
}