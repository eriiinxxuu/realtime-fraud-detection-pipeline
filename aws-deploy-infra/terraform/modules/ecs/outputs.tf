# ============================================================
# Output values exposed to other modules
# ============================================================

output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "cluster_id" {
  description = "ECS cluster ID"
  value       = aws_ecs_cluster.main.id
}

output "service_names" {
  description = "Map of all ECS service names"
  value = {
    airflow_apiserver     = aws_ecs_service.airflow_apiserver.name
    airflow_scheduler     = aws_ecs_service.airflow_scheduler.name
    airflow_dag_processor = aws_ecs_service.airflow_dag_processor.name
    airflow_worker        = aws_ecs_service.airflow_worker.name
    airflow_triggerer     = aws_ecs_service.airflow_triggerer.name
    mlflow_server         = aws_ecs_service.mlflow_server.name
    producer              = aws_ecs_service.producer.name
    inference             = aws_ecs_service.inference.name
  }
}