#!/bin/bash


set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER mlflow WITH PASSWORD 'mlflow';
    CREATE DATABASE mlflow OWNER mlflow;
    \connect mlflow

    ALTER SCHEMA public OWNER TO mlflow;
    GRANT USAGE, CREATE ON SCHEMA public TO mlflow;

    ALTER DEFAULT PRIVILEGES FOR USER mlflow IN SCHEMA public
    GRANT ALL ON TABLES TO mlflow;

    ALTER DEFAULT PRIVILEGES FOR USER mlflow IN SCHEMA public
    GRANT ALL ON SEQUENCES TO mlflow;

    ALTER DEFAULT PRIVILEGES FOR USER mlflow IN SCHEMA public
    GRANT ALL ON FUNCTIONS TO mlflow;
    
EOSQL