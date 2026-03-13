# ============================================================
# MSK Module — Overview
#
# Replaces local Kafka from docker-compose with AWS Managed
# Streaming for Kafka (MSK).
#
# Data flow:
#   producer (ECS) → MSK → Airflow DAG (daily training)
#                        → inference (ECS, real-time prediction)
#
# Resources created:
#   ├── MSK Cluster        → 2 brokers, one per AZ
#   ├── MSK Configuration  → Kafka settings
#   └── Secrets Manager
#       └── bootstrap-servers → injected into producer + inference
# ============================================================

# ---------- MSK Configuration ----------
resource "aws_msk_configuration" "main" {
  name              = "${var.project_name}-kafka-config"
  kafka_versions    = ["3.6.0"]

  server_properties = <<-EOT
    # Allow topics to be deleted
    delete.topic.enable = true

    # Keep messages for 7 days
    log.retention.hours = 168

    # 50MB max message size
    message.max.bytes = 52428800

    # Auto create topics when producer writes to them
    auto.create.topics.enable = true
  EOT
}

# ---------- MSK Cluster ----------
resource "aws_msk_cluster" "main" {
  cluster_name           = "${var.project_name}-kafka"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type  = var.broker_instance_type
    client_subnets = var.private_subnet_ids
    storage_info {
      ebs_storage_info {
        volume_size = 100
      }
    }
    security_groups = [var.msk_sg_id]
  }

  configuration_info {
    arn      = aws_msk_configuration.main.arn
    revision = aws_msk_configuration.main.latest_revision
  }

  # Encryption
  encryption_info {
    encryption_in_transit {
      client_broker = "PLAINTEXT"  # Keep simple — no TLS between ECS and MSK
      in_cluster    = true         # Encrypt between brokers
    }
  }

  # Authentication — no auth needed since MSK is private within VPC
  client_authentication {
    unauthenticated = true
  }

  # Logging — send Kafka broker logs to CloudWatch
  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  tags = { Name = "${var.project_name}-kafka" }
}

# CloudWatch log group for MSK broker logs
resource "aws_cloudwatch_log_group" "msk" {
  name              = "/msk/${var.project_name}"
  retention_in_days = 7

  tags = { Name = "${var.project_name}-msk-logs" }
}

# ---------- Secrets Manager ----------
# Store bootstrap servers URL — injected into producer and inference containers
resource "aws_secretsmanager_secret" "bootstrap_servers" {
  name                    = "${var.project_name}/msk/bootstrap-servers"
  recovery_window_in_days = 7
  tags                    = { Name = "${var.project_name}-msk-bootstrap-servers" }
}

resource "aws_secretsmanager_secret_version" "bootstrap_servers" {
  secret_id     = aws_secretsmanager_secret.bootstrap_servers.id
  secret_string = aws_msk_cluster.main.bootstrap_brokers

  depends_on = [aws_msk_cluster.main]
}