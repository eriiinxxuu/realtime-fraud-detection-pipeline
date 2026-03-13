variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  default = "fraud-detection" 
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ElastiCache subnet group"
  type        = list(string)
}

variable "elasticache_sg_id" {
  description = "Security group ID for ElastiCache Redis"
  type        = string
}

variable "node_type" {
  description = "ElastiCache node instance type"
  type        = string
  default     = "cache.t3.small"
}