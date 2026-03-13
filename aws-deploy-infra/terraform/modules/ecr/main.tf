# ============================================================
# ECR Module — Overview
#
# Creates one private Docker image repository per service:
#   ├── fraud-detection/airflow    → used by all 5 Airflow containers
#   ├── fraud-detection/mlflow     → MLflow server
#   ├── fraud-detection/producer   → Kafka producer
#   └── fraud-detection/inference  → Model inference
#
# Each repo has:
#   ├── Image scanning on push     → detects security vulnerabilities
#   ├── AES256 encryption          → images encrypted at rest
#   └── Lifecycle policy           → keeps last 3 images, removes old ones
# ============================================================

locals {
  services = ["airflow", "mlflow", "producer", "inference"]
}

resource "aws_ecr_repository" "services" {
  for_each             = toset(local.services)
  name                 = "${var.project_name}/${each.key}"
  image_tag_mutability = "MUTABLE"

  # Automatically scan for vulnerabilities every time an image is pushed
  image_scanning_configuration {
    scan_on_push = true
  }

  # Encrypt images at rest
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Name = "${var.project_name}-${each.key}-ecr" }
}

# Lifecycle policy — keeps storage costs low
# Keeps last 3 tagged images, removes untagged images after 7 days
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        # Keep the last 3 tagged images (sha- or v prefix)
        rulePriority = 1
        description  = "Keep last 3 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-", "v"]
          countType     = "imageCountMoreThan"
          countNumber   = 3
        }
        action = { type = "expire" }
      },
      {
        # Remove untagged images after 7 days
        rulePriority = 2
        description  = "Remove untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}