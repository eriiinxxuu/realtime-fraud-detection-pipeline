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

# ============================================================
# S3 Bucket — Fraud Detection Inference Results
#
# Stores fraud prediction outputs from the Spark Streaming
# inference service (replaces Kafka output topic).
#
# Path convention:
#   s3://<project>-inference-results/predictions/YYYY/MM/DD/
# ============================================================

resource "aws_s3_bucket" "inference_results" {
  bucket        = "${var.project_name}-inference-results"
  force_destroy = false

  tags = { Name = "${var.project_name}-inference-results" }
}

resource "aws_s3_bucket_versioning" "inference_results" {
  bucket = aws_s3_bucket.inference_results.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "inference_results" {
  bucket = aws_s3_bucket.inference_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "inference_results" {
  bucket                  = aws_s3_bucket.inference_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 保留 90 天完整记录，之后转 Infrequent Access，365 天后归档
resource "aws_s3_bucket_lifecycle_configuration" "inference_results" {
  bucket = aws_s3_bucket.inference_results.id

  rule {
    id     = "archive-old-predictions"
    status = "Enabled"

    filter { prefix = "predictions/" }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }
  }
}
