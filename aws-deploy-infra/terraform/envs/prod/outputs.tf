# ============================================================
# Outputs — useful info after terraform apply
# ============================================================

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs.cluster_name
}

output "ecr_repository_urls" {
  description = "ECR repository URLs for each service"
  value       = module.ecr.repository_urls
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions — add this to GitHub Secrets"
  value       = module.iam.github_actions_role_arn
}

output "rds_endpoint" {
  description = "RDS instance endpoint"
  value       = module.rds.db_address
}

output "msk_bootstrap_brokers" {
  description = "MSK bootstrap broker endpoints"
  value       = module.msk.bootstrap_brokers
}