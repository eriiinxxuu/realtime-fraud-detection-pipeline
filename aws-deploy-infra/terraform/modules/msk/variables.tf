variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  default = "fraud-detection"
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for MSK brokers (need exactly 2)"
  type        = list(string)
}

variable "msk_sg_id" {
  description = "Security group ID for MSK"
  type        = string
}

variable "broker_instance_type" {
  description = "MSK broker instance type"
  type        = string
  default     = "kafka.t3.small"
}