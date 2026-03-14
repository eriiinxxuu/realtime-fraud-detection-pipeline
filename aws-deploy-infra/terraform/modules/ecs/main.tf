# ============================================================
# ECS Module — Overview
#
# Creates ECS Cluster + all services:
#
#   Airflow (5 services, shared image + git-sync sidecar)
#   ├── airflow-apiserver      → Airflow UI + API
#   ├── airflow-scheduler      → schedules DAGs
#   ├── airflow-dag-processor  → parses DAG files
#   ├── airflow-worker x2      → executes tasks
#   └── airflow-triggerer      → handles async tasks
#
#   ML Services
#   ├── mlflow-server          → experiment tracking
#   ├── producer x2            → writes events to MSK
#   └── inference              → Spark Streaming fraud detection
# 8 services total, all running on Fargate with shared ECR images \\
# and git-sync sidecars for Airflow. 
# Airflow containers:
#   └── git-sync sidecar pulls DAGs from GitHub every 60s
#       into shared emptyDir volume at /opt/airflow/dags
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
# Shared locals
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
    { name = "RDS_HOST", value = "fraud-detection-postgres.cbu00k8auquu.ap-southeast-2.rds.amazonaws.com" },
    { name = "AIRFLOW__CORE__DAGS_FOLDER", value = "/opt/airflow/dags/dags" },
  ]

  airflow_secrets = [
    {
      name      = "AIRFLOW__DATABASE__SQL_ALCHEMY_CONN"
      valueFrom = var.airflow_db_url_secret_arn
    },
    {
      name      = "AIRFLOW__CELERY__RESULT_BACKEND"
      valueFrom = var.airflow_celery_result_backend_secret_arn
    },
    {
      name      = "AIRFLOW__CELERY__BROKER_URL"
      valueFrom = var.redis_url_secret_arn
    },
    {
      name      = "AIRFLOW__API_AUTH__JWT_SECRET"
      valueFrom = var.airflow_jwt_secret_arn
    },
    {
      name      = "MASTER_DB_PASSWORD"
      valueFrom = var.master_db_password_secret_arn
    },
    {
      name      = "AIRFLOW_DB_PASSWORD"
      valueFrom = var.airflow_db_password_secret_arn
    },
    {
      name      = "MLFLOW_DB_PASSWORD"
      valueFrom = var.mlflow_db_password_secret_arn
    },
  ]

  # git-sync sidecar — shared across all Airflow task definitions
  git_sync_container = {
    name      = "git-sync"
    image     = "registry.k8s.io/git-sync/git-sync:v4.2.1"
    essential = false
    user = "0"

    environment = [
      { name = "GITSYNC_REPO",   value = var.github_repo_url },
      { name = "GITSYNC_BRANCH", value = "main" },
      { name = "GITSYNC_ROOT",   value = "tmp//git" },
      { name = "GITSYNC_LINK",   value = "dags" },
      { name = "GITSYNC_PERIOD", value = "60s" },
      { name = "GITSYNC_DEPTH",  value = "1" },
      { name = "GITSYNC_SUBDIR", value = "src/dags" },
    ]

    mountPoints = [{
      sourceVolume  = "dags-git"
      containerPath = "/tmp/git"
      readOnly      = false
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}/airflow-apiserver"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "git-sync"
      }
    }
  }

  dags_volume_name = "dags-git"
}

# ============================================================
# Service Discovery
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
    name = local.dags_volume_name
  }

  container_definitions = jsonencode([
    {
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
        sourceVolume  = local.dags_volume_name
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
    },
    local.git_sync_container
  ])

  tags = { Name = "${var.project_name}-airflow-apiserver" }
}

resource "aws_ecs_service" "airflow_apiserver" {
  name                 = "airflow-apiserver"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.airflow_apiserver.arn
  desired_count        = 1
  launch_type          = "FARGATE"
  force_new_deployment = true
  enable_execute_command = true

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
    enable   = true
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
    name = local.dags_volume_name
  }

  container_definitions = jsonencode([
    {
      name      = "airflow-scheduler"
      image     = "${var.ecr_urls["airflow"]}:${var.image_tag}"
      command   = ["scheduler"]
      essential = true

      environment = local.airflow_environment
      secrets     = local.airflow_secrets

      mountPoints = [{
        sourceVolume  = local.dags_volume_name
        containerPath = "/opt/airflow/dags"
        readOnly      = true
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
    },
    local.git_sync_container
  ])

  tags = { Name = "${var.project_name}-airflow-scheduler" }
}

resource "aws_ecs_service" "airflow_scheduler" {
  name                 = "airflow-scheduler"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.airflow_scheduler.arn
  desired_count        = 1
  launch_type          = "FARGATE"
  force_new_deployment = true
  enable_execute_command = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  deployment_circuit_breaker {
    enable   = true
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
    name = local.dags_volume_name
  }

  container_definitions = jsonencode([
    {
      name      = "airflow-dag-processor"
      image     = "${var.ecr_urls["airflow"]}:${var.image_tag}"
      command   = ["dag-processor"]
      essential = true

      environment = local.airflow_environment
      secrets     = local.airflow_secrets

      mountPoints = [{
        sourceVolume  = local.dags_volume_name
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
    },
    local.git_sync_container
  ])

  tags = { Name = "${var.project_name}-airflow-dag-processor" }
}

resource "aws_ecs_service" "airflow_dag_processor" {
  name                 = "airflow-dag-processor"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.airflow_dag_processor.arn
  desired_count        = 1
  launch_type          = "FARGATE"
  force_new_deployment = true
  enable_execute_command = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  deployment_circuit_breaker {
    enable   = true
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
    name = local.dags_volume_name
  }

  container_definitions = jsonencode([
    {
      name      = "airflow-worker"
      image     = "${var.ecr_urls["airflow"]}:${var.image_tag}"
      command   = ["celery", "worker"]
      essential = true

      environment = concat(local.airflow_environment, [
        { name = "DUMB_INIT_SETSID", value = "0" },
        { name = "AIRFLOW__CELERY__WORKER_CONCURRENCY", value = "4" },
        { name = "AIRFLOW__CELERY__POOL", value = "solo" },
      ])
      secrets = local.airflow_secrets

      mountPoints = [{
        sourceVolume  = local.dags_volume_name
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
    },
    local.git_sync_container
  ])

  tags = { Name = "${var.project_name}-airflow-worker" }
}

resource "aws_ecs_service" "airflow_worker" {
  name                 = "airflow-worker"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.airflow_worker.arn
  desired_count        = 2
  launch_type          = "FARGATE"
  force_new_deployment = true
  enable_execute_command = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  deployment_circuit_breaker {
    enable   = true
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
    name = local.dags_volume_name
  }

  container_definitions = jsonencode([
    {
      name      = "airflow-triggerer"
      image     = "${var.ecr_urls["airflow"]}:${var.image_tag}"
      command   = ["triggerer"]
      essential = true

      environment = local.airflow_environment
      secrets     = local.airflow_secrets

      mountPoints = [{
        sourceVolume  = local.dags_volume_name
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
    },
    local.git_sync_container
  ])

  tags = { Name = "${var.project_name}-airflow-triggerer" }
}

resource "aws_ecs_service" "airflow_triggerer" {
  name                 = "airflow-triggerer"
  cluster              = aws_ecs_cluster.main.id
  task_definition      = aws_ecs_task_definition.airflow_triggerer.arn
  desired_count        = 1
  launch_type          = "FARGATE"
  force_new_deployment = true
  enable_execute_command = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_sg_id]
  }

  deployment_circuit_breaker {
    enable   = true
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
    "sh", "-c",
    "mlflow server --port 5500 --host 0.0.0.0 --backend-store-uri $MLFLOW_DB_URL --default-artifact-root s3://${var.mlflow_bucket_name}/ --allowed-hosts *"
    ] 

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}/mlflow-server"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
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
    enable   = true
    rollback = true
  }
  tags = { Name = "${var.project_name}-mlflow-server" }
  lifecycle {
    ignore_changes = [desired_count]
  }
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
    enable   = true
    rollback = true
  }
  tags = { Name = "${var.project_name}-producer" }
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ============================================================
# SERVICE: inference (Spark Structured Streaming)
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
    enable   = true
    rollback = true
  }
  tags = { Name = "${var.project_name}-inference" }
}