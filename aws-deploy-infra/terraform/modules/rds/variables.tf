variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  default = "fraud-detection"
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for RDS subnet group"
  type        = list(string)
}

variable "rds_sg_id" {
  description = "Security group ID for RDS"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance type"
  type        = string
  default     = "db.t3.medium"
}

variable "db_master_password" {
  description = "Master password for RDS"
  type        = string
  sensitive   = true
}

variable "airflow_db_password" {
  description = "Password for airflow database user"
  type        = string
  sensitive   = true
}

variable "mlflow_db_password" {
  description = "Password for mlflow database user"
  type        = string
  sensitive   = true
}