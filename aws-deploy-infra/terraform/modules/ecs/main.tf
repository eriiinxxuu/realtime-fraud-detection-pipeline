# ============================================================
# ECS Module — Overview
#
# Creates ECS Cluster + all services mirroring docker-compose:
#
#   Airflow (5 services, shared image)
#   ├── airflow-apiserver      → Airflow UI + API
#   ├── airflow-scheduler      → schedules DAGs
#   ├── airflow-dag-processor  → parses DAG files from EFS
#   ├── airflow-worker x2      → executes tasks
#   └── airflow-triggerer      → handles async tasks
#
#   ML Services
#   ├── mlflow-server          → experiment tracking
#   ├── producer x2            → writes events to MSK
#   └── inference              → Spark Streaming fraud detection
#
# 8 containers in total
#
# All containers:
#   ├── pull images from ECR (via VPC Endpoint)
#   ├── send logs to CloudWatch (via VPC Endpoint)
#   └── read secrets from Secrets Manager (via VPC Endpoint)
#
# Airflow containers additionally:
#   └── mount EFS for shared DAG files
# ============================================================

# ---------- ECS Cluster ----------
resource "aws_ecs_cluster" "main" {
  name = var.project_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.project_name}-cluster" }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ---------- CloudWatch Log Groups ----------
locals {
  services = [
    "airflow-apiserver",
    "airflow-scheduler",
    "airflow-dag-processor",
    "airflow-worker",
    "airflow-triggerer",
    "mlflow-server",
    "producer",
    "inference"
  ]
}

resource "aws_cloudwatch_log_group" "services" {
  for_each          = toset(local.services)
  name              = "/ecs/${var.project_name}/${each.key}"
  retention_in_days = 7

  tags = { Name = "${var.project_name}-${each.key}-logs" }
}

# ============================================================
# Shared: Airflow environment variables
# Mirrors x-airflow-common from docker-compose
# ============================================================
locals {
  airflow_environment = [
    { name = "AIRFLOW__CORE__EXECUTOR",                    value = "CeleryExecutor" },
    { name = "AIRFLOW__CORE__AUTH_MANAGER",                value = "airflow.providers.fab.auth_manager.fab_auth_manager.FabAuthManager" },
    { name = "AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION", value = "true" },
    { name = "AIRFLOW__CORE__LOAD_EXAMPLES",               value = "false" },
    { name = "AIRFLOW__SCHEDULER__ENABLE_HEALTH_CHECK",    value = "true" },
    { name = "AIRFLOW__CORE__EXECUTION_API_SERVER_URL",    value = "http://airflow-apiserver.${var.project_name}.local:8080/execution/" },
    { name = "MLFLOW_TRACKING_URI",                        value = "http://mlflow-server.${var.project_name}.local:5500" },
    { name = "AWS_DEFAULT_REGION",                         value = var.aws_region },
  ]

  airflow_secrets = [
    {
      name      = "AIRFLOW__DATABASE__SQL_ALCHEMY_CONN"
      valueFrom = var.airflow_db_url_secret_arn
    },
    {
      name      = "AIRFLOW__CELERY__RESULT_BACKEND"
      valueFrom = var.airflow_db_url_secret_arn
    },
    {
      name      = "AIRFLOW__CELERY__BROKER_URL"
      valueFrom = var.redis_url_secret_arn
    },
    {
      name      = "AIRFLOW__API_AUTH__JWT_SECRET"
      valueFrom = var.airflow_jwt_secret_arn
    },
  ]

  efs_volume_name = "dags-efs"
}

# ============================================================
# Service Discovery — internal DNS for inter-service comms
# e.g. mlflow-server.fraud-detection.local:5500
# ============================================================
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${var.project_name}.local"
  description = "Internal DNS for ECS services"
  vpc         = var.vpc_id

  tags = { Name = "${var.project_name}-dns-namespace" }
}

# ============================================================
# SERVICE: airflow-apiserver
# ============================================================
resource "aws_ecs_task_definition" "airflow_apiserver" {
  family                   = "${var.project_name}-airflow-apiserver"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  volume {
    name = local.efs_volume_name
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "airflow-apiserver"
    image     = "${var.ecr_urls["airflow"]}:${var.image_tag}"
    command   = ["api-server"]
    essential = true

    portMappings = [{
      name          = "airflow-api"    
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = local.airflow_environment
    secrets     = local.airflow_secrets

    mountPoints = [{
      sourceVolume  = local.efs_volume_name
      containerPath = "/opt/airflow/dags"
      readOnly      = true
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}/airflow-apiserver"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8080/api/v2/version || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 5
      startPeriod = 60
    }
  }])

  tags = { Name = "${var.project_name}-airflow-apiserver" }
}

resource "aws_ecs_service" "airflow_apiserver" {
  name                 = "airflow-apiserver"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.airflow_apiserver.arn
  desired_count        = 1
  launch_type          = "FARGATE"
  force_new_deployment = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.main.arn

    service {
      port_name      = "airflow-api"
      discovery_name = "airflow-apiserver"
      client_alias {
        port     = 8080
        dns_name = "airflow-apiserver"
      }
    }
  }

  deployment_circuit_breaker { 
    enable = true
    rollback = true 
    }
  tags = { Name = "${var.project_name}-airflow-apiserver" }
}

# ============================================================
# SERVICE: airflow-scheduler
# ============================================================
resource "aws_ecs_task_definition" "airflow_scheduler" {
  family                   = "${var.project_name}-airflow-scheduler"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  volume {
    name = local.efs_volume_name
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "airflow-scheduler"
    image     = "${var.ecr_urls["airflow"]}:${var.image_tag}"
    command   = ["scheduler"]
    essential = true

    environment = local.airflow_environment
    secrets     = local.airflow_secrets

    mountPoints = [{
      sourceVolume  = local.efs_volume_name
      containerPath = "/opt/airflow/dags"
      readOnly      = false
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}/airflow-scheduler"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8974/health || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 5
      startPeriod = 60
    }
  }])

  tags = { Name = "${var.project_name}-airflow-scheduler" }
}

resource "aws_ecs_service" "airflow_scheduler" {
  name                 = "airflow-scheduler"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.airflow_scheduler.arn
  desired_count        = 1
  launch_type          = "FARGATE"
  force_new_deployment = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  deployment_circuit_breaker {
    enable = true
    rollback = true 
  }
  tags = { Name = "${var.project_name}-airflow-scheduler" }
}

# ============================================================
# SERVICE: airflow-dag-processor
# ============================================================
resource "aws_ecs_task_definition" "airflow_dag_processor" {
  family                   = "${var.project_name}-airflow-dag-processor"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  volume {
    name = local.efs_volume_name
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "airflow-dag-processor"
    image     = "${var.ecr_urls["airflow"]}:${var.image_tag}"
    command   = ["dag-processor"]
    essential = true

    environment = local.airflow_environment
    secrets     = local.airflow_secrets

    mountPoints = [{
      sourceVolume  = local.efs_volume_name
      containerPath = "/opt/airflow/dags"
      readOnly      = true
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}/airflow-dag-processor"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = { Name = "${var.project_name}-airflow-dag-processor" }
}

resource "aws_ecs_service" "airflow_dag_processor" {
  name                 = "airflow-dag-processor"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.airflow_dag_processor.arn
  desired_count        = 1
  launch_type          = "FARGATE"
  force_new_deployment = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  deployment_circuit_breaker {
    enable = true
    rollback = true
    }
  tags = { Name = "${var.project_name}-airflow-dag-processor" }
}

# ============================================================
# SERVICE: airflow-worker (x2)
# ============================================================
resource "aws_ecs_task_definition" "airflow_worker" {
  family                   = "${var.project_name}-airflow-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  volume {
    name = local.efs_volume_name
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "airflow-worker"
    image     = "${var.ecr_urls["airflow"]}:${var.image_tag}"
    command   = ["celery", "worker"]
    essential = true

    environment = concat(local.airflow_environment, [
      { name = "DUMB_INIT_SETSID", value = "0" }
    ])
    secrets = local.airflow_secrets

    mountPoints = [{
      sourceVolume  = local.efs_volume_name
      containerPath = "/opt/airflow/dags"
      readOnly      = true
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}/airflow-worker"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = { Name = "${var.project_name}-airflow-worker" }
}

resource "aws_ecs_service" "airflow_worker" {
  name                 = "airflow-worker"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.airflow_worker.arn
  desired_count        = 2
  launch_type          = "FARGATE"
  force_new_deployment = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  deployment_circuit_breaker {
    enable = true
    rollback = true
    }
  tags = { Name = "${var.project_name}-airflow-worker" }
}

# ============================================================
# SERVICE: airflow-triggerer
# ============================================================
resource "aws_ecs_task_definition" "airflow_triggerer" {
  family                   = "${var.project_name}-airflow-triggerer"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  volume {
    name = local.efs_volume_name
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "airflow-triggerer"
    image     = "${var.ecr_urls["airflow"]}:${var.image_tag}"
    command   = ["triggerer"]
    essential = true

    environment = local.airflow_environment
    secrets     = local.airflow_secrets

    mountPoints = [{
      sourceVolume  = local.efs_volume_name
      containerPath = "/opt/airflow/dags"
      readOnly      = true
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}/airflow-triggerer"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = { Name = "${var.project_name}-airflow-triggerer" }
}

resource "aws_ecs_service" "airflow_triggerer" {
  name                 = "airflow-triggerer"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.airflow_triggerer.arn
  desired_count        = 1
  launch_type          = "FARGATE"
  force_new_deployment = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  deployment_circuit_breaker {
    enable = true
    rollback = true
    }
  tags = { Name = "${var.project_name}-airflow-triggerer" }
}

# ============================================================
# SERVICE: mlflow-server
# ============================================================
resource "aws_ecs_task_definition" "mlflow_server" {
  family                   = "${var.project_name}-mlflow-server"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "mlflow-server"
    image     = "${var.ecr_urls["mlflow"]}:${var.image_tag}"
    essential = true

    portMappings = [{
      name          = "mlflow"        
      containerPort = 5500
      protocol      = "tcp"
    }]

    environment = [
      { name = "AWS_DEFAULT_REGION", value = var.aws_region }
    ]

    secrets = [
      { name = "MLFLOW_DB_URL", valueFrom = var.mlflow_db_url_secret_arn }
    ]

    command = [
      "mlflow", "server",
      "--port", "5500",
      "--host", "0.0.0.0",
      "--backend-store-uri", "$(MLFLOW_DB_URL)",
      "--default-artifact-root", "s3://${var.mlflow_bucket_name}/",
      "--allowed-hosts", "*"
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}/mlflow-server"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:5500/health || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 3
      startPeriod = 30
    }
  }])

  tags = { Name = "${var.project_name}-mlflow-server" }
}

resource "aws_ecs_service" "mlflow_server" {
  name                 = "mlflow-server"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.mlflow_server.arn
  desired_count        = 1
  launch_type          = "FARGATE"
  force_new_deployment = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.main.arn

    service {
      port_name      = "mlflow"
      discovery_name = "mlflow-server"
      client_alias {
        port     = 5500
        dns_name = "mlflow-server"
      }
    }
  }

  deployment_circuit_breaker {
    enable = true
    rollback = true
    }
  tags = { Name = "${var.project_name}-mlflow-server" }
}

# ============================================================
# SERVICE: producer (x2)
# ============================================================
resource "aws_ecs_task_definition" "producer" {
  family                   = "${var.project_name}-producer"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "producer"
    image     = "${var.ecr_urls["producer"]}:${var.image_tag}"
    essential = true

   environment = [
    { name = "AWS_DEFAULT_REGION",      value = var.aws_region },
    { name = "KAFKA_SECURITY_PROTOCOL", value = "PLAINTEXT" },
    { name = "KAFKA_SASL_MECHANISM",    value = "" },
  ]

    secrets = [
      { name = "KAFKA_BOOTSTRAP_SERVERS", valueFrom = var.bootstrap_servers_secret_arn }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}/producer"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = { Name = "${var.project_name}-producer" }
}

resource "aws_ecs_service" "producer" {
  name                 = "producer"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.producer.arn
  desired_count        = 2
  launch_type          = "FARGATE"
  force_new_deployment = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  deployment_circuit_breaker {
    enable = true
    rollback = true
    }
  tags = { Name = "${var.project_name}-producer" }
}

# ============================================================
# SERVICE: inference (Spark Structured Streaming)
# 4 vCPU, 8GB — Spark needs more resources
# ============================================================
resource "aws_ecs_task_definition" "inference" {
  family                   = "${var.project_name}-inference"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 4096
  memory                   = 8192
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "inference"
    image     = "${var.ecr_urls["inference"]}:${var.image_tag}"
    essential = true

    environment = [
    { name = "AWS_DEFAULT_REGION",      value = var.aws_region },
    { name = "MLFLOW_TRACKING_URI",     value = "http://mlflow-server.${var.project_name}.local:5500" },
    { name = "KAFKA_SECURITY_PROTOCOL", value = "PLAINTEXT" },
    { name = "KAFKA_SASL_MECHANISM",    value = "" },
    { name = "MLFLOW_S3_ENDPOINT_URL",  value = "" },
  ]

    secrets = [
      { name = "KAFKA_BOOTSTRAP_SERVERS", valueFrom = var.bootstrap_servers_secret_arn }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}/inference"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = { Name = "${var.project_name}-inference" }
}

resource "aws_ecs_service" "inference" {
  name                 = "inference"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.inference.arn
  desired_count        = 1
  launch_type          = "FARGATE"
  force_new_deployment = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  deployment_circuit_breaker {
    enable = true
    rollback = true
    }
  tags = { Name = "${var.project_name}-inference" }
}