# Airflow DAG trains model
#      ↓
# MLflow logs experiment + saves model
#      ↓
# S3 bucket (fraud-detection-mlflow-artifacts)
#      ↓
# Inference container loads model from S3


# ============================================================
# S3 Module — Overview
#
# Replaces MinIO from docker-compose with native AWS S3.
# Used by MLflow to store trained model artifacts.
#
# Resources created:
#   └── S3 Bucket (fraud-detection-mlflow-artifacts)
#       ├── Versioning enabled      → keep history of model versions
#       ├── Encryption at rest      → AES256
#       ├── Public access blocked   → private, internal access only
#       └── Lifecycle policy        → move old models to cheaper storage
# ============================================================

resource "aws_s3_bucket" "mlflow_artifacts" {
  bucket        = "${var.project_name}-mlflow-artifacts"
  force_destroy = false

  tags = { Name = "${var.project_name}-mlflow-artifacts" }
}

# Keep history of every model version
resource "aws_s3_bucket_versioning" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt all model files at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access — only ECS containers can access via VPC Endpoint
resource "aws_s3_bucket_public_access_block" "mlflow_artifacts" {
  bucket                  = aws_s3_bucket.mlflow_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Move models older than 90 days to cheaper storage (S3 Infrequent Access)
resource "aws_s3_bucket_lifecycle_configuration" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  rule {
    id     = "transition-old-models"
    status = "Enabled"

    filter {
      prefix = ""
    }

    # After 90 days move to cheaper storage tier
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}