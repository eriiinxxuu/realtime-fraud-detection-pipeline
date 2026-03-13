# Input variables for the networking module


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

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}