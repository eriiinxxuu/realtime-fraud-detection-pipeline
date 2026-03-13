output "redis_endpoint" {
  description = "Redis primary endpoint address"
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "redis_url_secret_arn" {
  description = "Secrets Manager ARN for Redis broker URL"
  value       = aws_secretsmanager_secret.redis_url.arn
}