# ============================================================
# Production Environment — Entry Point
#
# Wires all modules together:
#   iam → networking → ecr → rds → elasticache → s3 → msk → ecs
#
# To deploy:
#   terraform init
#   terraform plan
#   terraform apply
# ============================================================



# ============================================================
# Airflow JWT Secret
# ============================================================
resource "aws_secretsmanager_secret" "airflow_jwt" {
  name                    = "${var.project_name}/airflow/jwt-secret"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "airflow_jwt" {
  secret_id     = aws_secretsmanager_secret.airflow_jwt.id
  secret_string = var.airflow_jwt_secret
}

# ============================================================
# Modules
# ============================================================

module "iam" {
  source = "../../modules/iam"

  project_name    = var.project_name
  aws_region      = var.aws_region
  aws_account_id  = var.aws_account_id
  github_org      = var.github_org
  github_repo     = var.github_repo
  tf_state_bucket = var.tf_state_bucket
}

module "networking" {
  source = "../../modules/networking"

  project_name = var.project_name
  aws_region   = var.aws_region
  vpc_cidr     = "10.0.0.0/16"
}

module "ecr" {
  source = "../../modules/ecr"

  project_name = var.project_name
}

module "s3" {
  source = "../../modules/s3"

  project_name = var.project_name
}

module "rds" {
  source = "../../modules/rds"

  project_name        = var.project_name
  private_subnet_ids  = module.networking.private_subnet_ids
  rds_sg_id           = module.networking.rds_sg_id
  db_master_password  = var.db_master_password
  airflow_db_password = var.airflow_db_password
  mlflow_db_password  = var.mlflow_db_password
}

module "elasticache" {
  source = "../../modules/elasticache"

  project_name       = var.project_name
  private_subnet_ids = module.networking.private_subnet_ids
  elasticache_sg_id  = module.networking.elasticache_sg_id
}

module "msk" {
  source = "../../modules/msk"

  project_name       = var.project_name
  private_subnet_ids = module.networking.private_subnet_ids
  msk_sg_id          = module.networking.msk_sg_id
}

module "ecs" {
  source = "../../modules/ecs"

  project_name                 = var.project_name
  aws_region                   = var.aws_region
  vpc_id                       = module.networking.vpc_id
  private_subnet_ids           = module.networking.private_subnet_ids
  ecs_sg_id                    = module.networking.ecs_sg_id
  task_execution_role_arn      = module.iam.ecs_task_execution_role_arn
  task_role_arn                = module.iam.ecs_task_role_arn
  efs_id                       = module.networking.efs_id
  efs_access_point_id          = module.networking.efs_access_point_id
  airflow_db_url_secret_arn    = module.rds.airflow_db_url_secret_arn
  mlflow_db_url_secret_arn     = module.rds.mlflow_db_url_secret_arn
  redis_url_secret_arn         = module.elasticache.redis_url_secret_arn
  airflow_jwt_secret_arn       = aws_secretsmanager_secret.airflow_jwt.arn
  bootstrap_servers_secret_arn = module.msk.bootstrap_servers_secret_arn
  mlflow_bucket_name           = module.s3.mlflow_bucket_name
  ecr_urls                     = module.ecr.repository_urls
  image_tag                    = var.image_tag
}