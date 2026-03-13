#!/bin/bash
set -e

if [ "$1" = "scheduler" ]; then
  echo "Initializing databases..."
  PGPASSWORD=$MASTER_DB_PASSWORD psql \
    "host=$RDS_HOST port=5432 dbname=postgres user=master sslmode=require" \
    -c "CREATE USER airflow WITH PASSWORD '$AIRFLOW_DB_PASSWORD';" \
    -c "CREATE DATABASE airflow OWNER airflow;" \
    -c "CREATE USER mlflow WITH PASSWORD '$MLFLOW_DB_PASSWORD';" \
    -c "CREATE DATABASE mlflow OWNER mlflow;" || true

  echo "Running db migrate..."
  airflow db migrate

  echo "Creating admin user..."
  airflow users create \
    --username admin \
    --password AdminPass123 \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com || true
fi

exec airflow "$@"