output "db_address" {
  description = "RDS instance hostname"
  value       = aws_db_instance.main.address
}

output "airflow_db_url_secret_arn" {
  description = "Secrets Manager ARN for Airflow DB connection string"
  value       = aws_secretsmanager_secret.airflow_db_url.arn
}

output "mlflow_db_url_secret_arn" {
  description = "Secrets Manager ARN for MLflow DB connection string"
  value       = aws_secretsmanager_secret.mlflow_db_url.arn
}