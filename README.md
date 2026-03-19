# Real-Time Financial Fraud Detection System

![Python](https://img.shields.io/badge/Python-3.9+-blue.svg)
![AWS](https://img.shields.io/badge/AWS-MSK_&_ECS_Fargate-232F3E.svg)
![Apache Spark](https://img.shields.io/badge/Apache_Spark-Structured_Streaming-E25A1C.svg)
![Airflow](https://img.shields.io/badge/Apache_Airflow-on_ECS-017CEE.svg)
![MLflow](https://img.shields.io/badge/MLflow-Experiment_Tracking-0194E2.svg)
![CI/CD](https://img.shields.io/badge/CI/CD-GitHub_Actions-2088FF.svg)
![Terraform](https://img.shields.io/badge/Terraform-Infrastructure_as_Code-623CE4.svg)
![Security](https://img.shields.io/badge/Network-Zero_Trust_Architecture-green.svg)

## 📚 Introduction
This project demonstrates an end-to-end, production-ready real-time fraud detection pipeline. This system features real-time stream processing using **AWS MSK** and **PySpark**, with automated workflows orchestrated by **Apache Airflow deployed on AWS ECS**. The entire stack is managed via a robust **CI/CD pipeline (GitHub Actions)** and defined as code (**IaC via Terraform**), ensuring seamless automation, high availability, and elastic scalability from infrastructure to deployment.

## Project Structure
```text
├── aws-deploy-infra/
│   └── terraform/              # Terraform IaC — VPC, ECS, RDS, MSK, S3, IAM
├── src/                        
│   ├── airflow/                # Airflow Dockerfile + entrypoint
│   ├── inference/              # Inference Dockerfile + Spark Structured Streaming inference service
│   ├── producer/               # producer Dockerfile + Kafka transaction producer (fake data)
│   ├── mlflow/                 # mlflow Dockerfile + MLflow server Dockerfile
│   └── dags/                   # DAGs + LightGBM training script
├── aws_deploy/                 # AWS deployment validation & UI screenshots
├── local_deploy/               # Local testing validation & screenshots
├── architecture/               # System architecture diagrams and technical deep-dives
│  
├── .github/
│   └── workflows/
│       ├── deploy-images.yml   # Build & push Docker images to ECR
│       └── terraform.yml       # Terraform plan & apply on infra changes
├── config.yaml                 # Shared config (Kafka, MLflow, Spark settings)
└── README.md
```

## 🏗️ System Architecture
![System Architecture](https://github.com/eriiinxxuu/realtime-fraud-detection-pipeline/blob/main/architecture/architecture-readme.png)

## 🔒 Network Topology & Security
* **Isolation:** All compute (ECS) and data (MSK, RDS) resources are hosted in **Isolated Private Subnets**.
* **Private Connectivity:** Utilized **AWS PrivateLink (Interface Endpoints)** and **Gateway Endpoints** to ensure that data transfer to S3, ECR, and Secrets Manager never leaves the AWS network.
* **Egress Control:** A centralized **NAT Gateway** handles strictly necessary outbound traffic, while security groups enforce a **Zero-Trust** policy between microservices.

![Network Architecture](https://github.com/eriiinxxuu/realtime-fraud-detection-pipeline/blob/main/architecture/network.png)

## 🚀 Key Engineering Highlights

- **Robust ECS Microservices Ecosystem**: Orchestrated 8 custom-built containerized services on AWS ECS (ARM64), including a fully decoupled Airflow stack (API, Scheduler, DAG Processor, Triggerer, Worker). Automated complex daily pipelines for MSK data extraction (150k batch) and feature engineering.
- **High-Throughput Stream Processing**: Leveraged PySpark & Apache Arrow (***pandas_udf***) for batch-vectorized predictions on **MSK** streams, bypassing Python serialization bottlenecks. Sunk real-time inference results to **S3 (Parquet)** partitioned by date for downstream **Athena** analytics.
- **End-to-End DataOps & MLOps**: Implemented dual-workflow **GitHub Actions** for seamless Infrastructure-as-Code (**Terraform**) deployment and container lifecycle management. Integrated **MLflow** as a centralized model registry to seamlessly bridge batch training outputs with the real-time PySpark inference engine.
- **Zero-Trust Networking**: Provisioned isolated private subnets via Terraform, utilizing Security Group chaining and VPC Endpoints (PrivateLink) to secure financial data streams and minimize NAT egress costs.

## 🛠️ Quick Start & Deployment

The infrastructure and application lifecycle are fully automated.

1. **Infrastructure (Terraform):** Navigate to `aws-deploy-infra/terraform/` and apply the configurations to provision the VPC, MSK, ECS cluster, and RDS.
   ```bash
   terraform init
   terraform plan
   terraform apply -auto-approve
   
2. **CI/CD Pipeline:** Pushing to the `main` branch automatically triggers GitHub Actions to build ARM64 Docker images, push them to Amazon ECR, and update the ECS services.

3. **Validation:** Check the `aws_deploy/` and `local_deploy/` folders for deployment screenshots, including Airflow DAG runs and MSK streaming logs.

## 📖 Detailed Documentation

For deep-dives into specific components and engineering decisions, please refer to the detailed documentation:

* [**System Architecture & Data Flow**](./architecture/system-architecture.md)
* [**Network Security & VPC Endpoints**](./architecture/network-security.md)
* [**PySpark Vectorization & Inference Optimization**](./architecture/inference.md)
* [**Airflow ECS Orchestration & Microservices**](./architecture/airflow.md)
