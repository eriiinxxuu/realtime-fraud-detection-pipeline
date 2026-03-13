
# RDS Module — Overview
#
# Creates a managed PostgreSQL 16 instance to replace the
# local postgres container from docker-compose.
#
# Resources created:
#   ├── DB Subnet Group        → tells RDS which subnets to use
#   ├── DB Parameter Group     → PostgreSQL configuration
#   ├── RDS Instance           → PostgreSQL 16
#   └── Secrets Manager
#       ├── master password
#       ├── airflow db url     → injected into Airflow containers
#       └── mlflow db url      → injected into MLflow container
# ============================================================

# ---------- Subnet Group ----------
# Tells RDS which private subnets it can live in
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.project_name}-db-subnet-group" }
}

# ---------- Parameter Group ----------
# PostgreSQL configuration settings
resource "aws_db_parameter_group" "main" {
  name   = "${var.project_name}-pg16"
  family = "postgres16"

  # Log queries that take longer than 1 second
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = { Name = "${var.project_name}-pg16" }
}

# ---------- Secrets Manager ----------
# Store passwords securely — never hardcoded in Terraform

resource "aws_secretsmanager_secret" "rds_master" {
  name                    = "${var.project_name}/rds/master-password"
  recovery_window_in_days = 7
  tags                    = { Name = "${var.project_name}-rds-master-password" }
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id     = aws_secretsmanager_secret.rds_master.id
  secret_string = var.db_master_password
}

resource "aws_secretsmanager_secret" "airflow_db_url" {
  name                    = "${var.project_name}/airflow/db-url"
  recovery_window_in_days = 7
  tags                    = { Name = "${var.project_name}-airflow-db-url" }
}

resource "aws_secretsmanager_secret_version" "airflow_db_url" {
  secret_id     = aws_secretsmanager_secret.airflow_db_url.id
  secret_string = "postgresql+psycopg2://airflow:${var.airflow_db_password}@${aws_db_instance.main.address}:5432/airflow"

  # Wait for RDS to be created first
  depends_on = [aws_db_instance.main]
}

resource "aws_secretsmanager_secret" "mlflow_db_url" {
  name                    = "${var.project_name}/mlflow/db-url"
  recovery_window_in_days = 7
  tags                    = { Name = "${var.project_name}-mlflow-db-url" }
}

resource "aws_secretsmanager_secret_version" "mlflow_db_url" {
  secret_id     = aws_secretsmanager_secret.mlflow_db_url.id
  secret_string = "postgresql+psycopg2://mlflow:${var.mlflow_db_password}@${aws_db_instance.main.address}:5432/mlflow"

  depends_on = [aws_db_instance.main]
}

# ---------- RDS Instance ----------
resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-postgres"

  # Engine
  engine         = "postgres"
  engine_version = "16.6"
  instance_class = var.db_instance_class

  # Storage
  allocated_storage     = 50
  max_allocated_storage = 200
  storage_type          = "gp3"
  storage_encrypted     = true

  # Credentials
  db_name  = "postgres"
  username = "master"
  password = var.db_master_password

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false

  # Backups
  backup_retention_period   = 7
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:04:00-sun:05:00"

  # Safety
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-final-snapshot"

  # Performance insights
  performance_insights_enabled = true

  tags = { Name = "${var.project_name}-postgres" }
}