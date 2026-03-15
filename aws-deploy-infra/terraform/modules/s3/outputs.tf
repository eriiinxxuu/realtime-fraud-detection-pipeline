output "mlflow_bucket_name" {
  description = "S3 bucket name for MLflow artifacts"
  value       = aws_s3_bucket.mlflow_artifacts.id
}

output "mlflow_bucket_arn" {
  description = "S3 bucket ARN for MLflow artifacts"
  value       = aws_s3_bucket.mlflow_artifacts.arn
}

output "inference_results_bucket_name" {
  value = aws_s3_bucket.inference_results.bucket
}