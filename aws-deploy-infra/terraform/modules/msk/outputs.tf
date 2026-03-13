output "bootstrap_brokers" {
  description = "MSK bootstrap broker endpoints"
  value       = aws_msk_cluster.main.bootstrap_brokers
}

output "bootstrap_servers_secret_arn" {
  description = "Secrets Manager ARN for MSK bootstrap servers"
  value       = aws_secretsmanager_secret.bootstrap_servers.arn
}