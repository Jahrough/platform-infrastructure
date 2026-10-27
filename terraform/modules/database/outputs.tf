output "endpoint" {
  description = "Private PostgreSQL endpoint, including its port."
  value       = aws_db_instance.postgres.endpoint
}

output "identifier" {
  description = "RDS instance identifier for monitoring dimensions."
  value       = aws_db_instance.postgres.identifier
}

output "master_user_secret_arn" {
  description = "AWS-managed master credential secret ARN; never use as an application credential."
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}
