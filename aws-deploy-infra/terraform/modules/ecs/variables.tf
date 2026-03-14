# ============================================================
# Input variables for the ECS module
# ============================================================

variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  default = "fraud-detection"
}

variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default = "ap-southeast-2" 
}

variable "vpc_id" {
  description = "VPC ID for service discovery namespace"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS services"
  type        = list(string)
}

variable "ecs_sg_id" {
  description = "Security group ID for ECS tasks"
  type        = string
}

variable "task_execution_role_arn" {
  description = "IAM role ARN for ECS task execution (pull images, fetch secrets)"
  type        = string
}

variable "task_role_arn" {
  description = "IAM role ARN for ECS tasks (app runtime permissions)"
  type        = string
}


variable "airflow_db_url_secret_arn" {
  description = "Secrets Manager ARN for Airflow database connection string"
  type        = string
}

variable "mlflow_db_url_secret_arn" {
  description = "Secrets Manager ARN for MLflow database connection string"
  type        = string
}

variable "redis_url_secret_arn" {
  description = "Secrets Manager ARN for Redis broker URL"
  type        = string
}

variable "airflow_jwt_secret_arn" {
  description = "Secrets Manager ARN for Airflow JWT secret"
  type        = string
}

variable "bootstrap_servers_secret_arn" {
  description = "Secrets Manager ARN for MSK bootstrap servers"
  type        = string
}

variable "mlflow_bucket_name" {
  description = "S3 bucket name for MLflow artifacts"
  type        = string
}

variable "ecr_urls" {
  description = "Map of service name to ECR repository URL"
  type        = map(string)
}

variable "image_tag" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}

variable "github_repo_url" {
  description = "GitHub repo URL for git-sync"
  type        = string
  default     = "https://github.com/eriiinxxuu/realtime-fraud-detection-pipeline"
}

variable "master_db_password_secret_arn" {
  description = "Secrets Manager ARN for RDS master password"
  type        = string
}

variable "airflow_db_password_secret_arn" {
  description = "Secrets Manager ARN for Airflow DB password"
  type        = string
}

variable "mlflow_db_password_secret_arn" {
  description = "Secrets Manager ARN for MLflow DB password"
  type        = string
}

variable "airflow_celery_result_backend_secret_arn" {
  description = "Secrets Manager ARN for Airflow Celery result backend"
  type        = string
}