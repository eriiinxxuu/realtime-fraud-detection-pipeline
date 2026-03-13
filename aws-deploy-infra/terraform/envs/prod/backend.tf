terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "frauddetection-tf-state-235695894568"
    key     = "prod/terraform.tfstate"
    region  = "ap-southeast-2"
    encrypt = true
  }
}

provider "aws" {
  region = "ap-southeast-2"

  default_tags {
    tags = {
      Project     = "fraud-detection"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}