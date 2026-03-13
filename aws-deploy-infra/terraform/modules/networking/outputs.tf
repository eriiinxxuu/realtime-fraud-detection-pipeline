# Output values exposed to other modules


# VPC
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

# Subnets
output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

# Security Groups
output "ecs_sg_id" {
  description = "Security group ID for ECS containers"
  value       = aws_security_group.ecs.id
}

output "rds_sg_id" {
  description = "Security group ID for RDS"
  value       = aws_security_group.rds.id
}

output "elasticache_sg_id" {
  description = "Security group ID for ElastiCache Redis"
  value       = aws_security_group.elasticache.id
}

output "msk_sg_id" {
  description = "Security group ID for MSK Kafka"
  value       = aws_security_group.msk.id
}

# EFS
output "efs_id" {
  description = "ID of the EFS file system for Airflow DAGs"
  value       = aws_efs_file_system.dags.id
}

output "efs_access_point_id" {
  description = "ID of the EFS access point for Airflow DAGs"
  value       = aws_efs_access_point.dags.id
}