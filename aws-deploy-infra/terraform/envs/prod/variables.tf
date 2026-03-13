# ============================================================
# Input variables for production environment
# Sensitive values are passed via GitHub Secrets, never hardcoded
# ============================================================

variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  default     = "fraud-detection"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "github_org" {
  description = "GitHub organization or username"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "tf_state_bucket" {
  description = "S3 bucket name for Terraform state"
  type        = string
}

variable "image_tag" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}

# Sensitive — never hardcode, always pass via environment variables or GitHub Secrets
variable "db_master_password" {
  description = "Master password for RDS"
  type        = string
  sensitive   = true
}

variable "airflow_db_password" {
  description = "Password for Airflow database user"
  type        = string
  sensitive   = true
}

variable "mlflow_db_password" {
  description = "Password for MLflow database user"
  type        = string
  sensitive   = true
}

variable "airflow_jwt_secret" {
  description = "JWT secret for Airflow API authentication"
  type        = string
  sensitive   = true
}