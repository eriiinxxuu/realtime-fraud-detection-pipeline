#  Airflow Scheduler
#      ↓ puts tasks into queue
#    Redis (broker)
#      ↓ workers pick up tasks
# Airflow Workers (x2)
#      ↓ results stored back in
#    PostgreSQL (result backend)


# ============================================================
# ElastiCache Module — Overview
#
# Creates a managed Redis 7.2 instance to replace the
# local redis container from docker-compose.
#
# Used by Airflow as Celery broker:
#   Scheduler → pushes tasks → Redis → Workers pull tasks
#
# Resources created:
#   ├── Subnet Group       → tells Redis which subnets to use
#   ├── Parameter Group    → Redis configuration
#   ├── Redis Instance     → single node (can scale later)
#   └── Secrets Manager
#       └── broker-url     → injected into all Airflow containers
# ============================================================

# ---------- Subnet Group ----------
resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project_name}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.project_name}-redis-subnet-group" }
}

# ---------- Parameter Group ----------
resource "aws_elasticache_parameter_group" "main" {
  name   = "${var.project_name}-redis7"
  family = "redis7"

  # When memory is full, remove least recently used keys
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }

  tags = { Name = "${var.project_name}-redis7" }
}

# ---------- Redis Instance ----------
resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.project_name}-redis"
  description          = "Redis broker for Airflow Celery workers"

  # Engine
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.node_type
  port                 = 6379

  # Single node for now — set to 2 for high availability
  num_cache_clusters   = 1

  parameter_group_name = aws_elasticache_parameter_group.main.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [var.elasticache_sg_id]

  # Encrypt data at rest and in transit
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false  # Airflow broker URL uses redis:// not rediss://

  # Keep 1 day of snapshots
  snapshot_retention_limit = 1
  snapshot_window          = "03:00-04:00"

  apply_immediately = true

  tags = { Name = "${var.project_name}-redis" }
}

# ---------- Secrets Manager ----------
# Store Redis connection URL — injected into all Airflow containers
resource "aws_secretsmanager_secret" "redis_url" {
  name                    = "${var.project_name}/redis/broker-url"
  recovery_window_in_days = 7
  tags                    = { Name = "${var.project_name}-redis-broker-url" }
}

resource "aws_secretsmanager_secret_version" "redis_url" {
  secret_id     = aws_secretsmanager_secret.redis_url.id
  secret_string = "redis://:@${aws_elasticache_replication_group.main.primary_endpoint_address}:6379/0"

  depends_on = [aws_elasticache_replication_group.main]
}