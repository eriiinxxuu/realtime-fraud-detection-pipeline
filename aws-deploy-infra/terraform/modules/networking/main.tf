# ============================================================
# Networking Module — Overview
# ============================================================
#
# This module creates the entire network foundation.
# No traffic enters or leaves the internet.
# All AWS service communication goes through VPC Endpoints.
#
# Resources created:
#
#   VPC
#   └── Private Subnets (x2, one per AZ)
#       ├── Route Table (no internet route)
#       │
#       ├── Security Groups
#       │   ├── ecs-sg             → ECS containers (all services)
#       │   ├── rds-sg             → RDS PostgreSQL (port 5432)
#       │   ├── redis-sg           → ElastiCache Redis (port 6379)
#       │   ├── msk-sg             → MSK Kafka (port 9092)
#       │   ├── efs-sg             → EFS file system (port 2049)
#       │   └── vpc-endpoints-sg   → VPC Endpoints (port 443)
#       │
#       ├── VPC Endpoints (private AWS service access)
#       │   ├── S3 Gateway         → MLflow model storage
#       │   ├── ECR API            → Docker image metadata
#       │   ├── ECR Docker         → Docker image layers
#       │   ├── CloudWatch Logs    → Container logs
#       │   ├── Secrets Manager    → DB passwords, JWT secrets
#       │   ├── SSM                → Session Manager UI access
#       │   ├── SSM Messages       → Session Manager
#       │   └── EC2 Messages       → Session Manager
#       │
#       └── EFS (Elastic File System)
#           └── /dags              → Shared DAG files for all Airflow containers
#
# ============================================================




data "aws_availability_zones" "available" {
  state = "available"
}

# ---------- VPC ----------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ---------- Private Subnets ----------
# All services live here: ECS, RDS, Redis, MSK, EFS
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-${count.index + 1}"
  }
}

# ---------- Private Route Table ----------
# No route to internet — all traffic stays within VPC or via endpoints
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}


# ---------- Security Groups ----------


# ECS containers
resource "aws_security_group" "ecs" {
  name        = "${var.project_name}-ecs-sg"
  description = "ECS tasks - allows traffic within VPC only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-ecs-sg" }
}

# RDS PostgreSQL
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "RDS PostgreSQL - only accessible from ECS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds-sg" }
}

# ElastiCache Redis
resource "aws_security_group" "elasticache" {
  name        = "${var.project_name}-redis-sg"
  description = "ElastiCache Redis - only accessible from ECS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-redis-sg" }
}

# MSK Kafka
resource "aws_security_group" "msk" {
  name        = "${var.project_name}-msk-sg"
  description = "MSK Kafka - only accessible from ECS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 9092
    to_port         = 9092
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-msk-sg" }
}

# EFS
resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs-sg"
  description = "EFS - NFS port only accessible from ECS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-efs-sg" }
}

# VPC Endpoints — shared security group
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-vpc-endpoints-sg"
  description = "VPC Endpoints - allows HTTPS from ECS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-vpc-endpoints-sg" }
}


#---------- VPC Endpoints ----------
# Allows private subnets to access AWS services without internet 


# S3 Gateway Endpoint
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project_name}-s3-endpoint" }
}

# ECR API — for Docker image metadata
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-ecr-api-endpoint" }
}

# ECR Docker — for pulling actual image layers
resource "aws_vpc_endpoint" "ecr_docker" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-ecr-dkr-endpoint" }
}

# CloudWatch Logs — for container logs
resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-cloudwatch-logs-endpoint" }
}

# Secrets Manager — for database passwords and JWT secrets
resource "aws_vpc_endpoint" "secrets_manager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-secretsmanager-endpoint" }
}

# SSM — for Session Manager (accessing Airflow/MLflow UI)
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-ssm-endpoint" }
}

# SSM Messages — required for Session Manager
resource "aws_vpc_endpoint" "ssm_messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-ssmmessages-endpoint" }
}

# EC2 Messages — required for Session Manager
resource "aws_vpc_endpoint" "ec2_messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project_name}-ec2messages-endpoint" }
}


# ---------- EFS ----------
# shared DAG storage for all Airflow containers

resource "aws_efs_file_system" "dags" {
  creation_token   = "${var.project_name}-dags"
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true

  tags = { Name = "${var.project_name}-dags-efs" }
}

# One mount target per private subnet
resource "aws_efs_mount_target" "dags" {
  count           = length(aws_subnet.private)
  file_system_id  = aws_efs_file_system.dags.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

# Access point — sets directory and permissions for Airflow (UID 50000)
resource "aws_efs_access_point" "dags" {
  file_system_id = aws_efs_file_system.dags.id

  posix_user {
    uid = 50000
    gid = 0
  }

  root_directory {
    path = "/dags"
    creation_info {
      owner_uid   = 50000
      owner_gid   = 0
      permissions = "755"
    }
  }

  tags = { Name = "${var.project_name}-dags-ap" }
}