# Input variables for the IAM module

variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  default = "fraud-detection" 
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default = "ap-southeast-2"
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