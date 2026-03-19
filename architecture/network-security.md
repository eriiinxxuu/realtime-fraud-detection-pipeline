# Network Security & VPC Endpoints Architecture

This document outlines the foundational network topology and security defense-in-depth strategy for the Real-Time Financial Fraud Detection System. Because financial and transaction data is highly sensitive, the infrastructure is built upon the **Principle of Least Privilege** and a **Zero-Trust Architecture**, implemented entirely via **Terraform**.
![network](https://github.com/eriiinxxuu/realtime-fraud-detection-pipeline/blob/main/architecture/network.png)
## Network Topology & Subnet Strategy

The project utilizes a highly available, Multi-AZ (Availability Zone) architecture to ensure fault tolerance:

- Public Subnets:

  - Host only the NAT Gateway and Internet Gateway (IGW).

  - Purpose: Serves as the single, tightly controlled egress point for private resources that occasionally require outbound internet access (e.g., Airflow tasks fetching external APIs or OS-level package updates).

- Private Subnets (The Core Enclave):

  - Host the 8 ECS Microservices (Airflow Stack, Inference, Producer, MLflow), the AWS MSK (Kafka) cluster, Amazon RDS, and ElastiCache (Redis).

  - Mechanism: Instances and containers in these subnets are not assigned public IP addresses. All outbound routing is directed either to the NAT Gateway or intercepted by local VPC Endpoints.

## Zero-Trust Security Group Chaining

In this system, I explicitly eliminate lateral movement risks by implementing Security Group (SG) Chaining. Rather than allowing broad CIDR blocks, data stores only accept traffic from specific compute identities:

- `ecs-sg` (Compute Enclave): Applied to all 8 ECS Fargate services. This acts as the universal "identity badge" for compute resources.
- `rds-sg` (PostgreSQL): Strictly restricted to allow inbound TCP traffic on port 5432 only from ecs-sg.
- `msk-sg` (Kafka): Restricted to allow inbound TCP traffic on port 9092 only from ecs-sg.
- `redis-sg` (ElastiCache): Restricted to allow inbound TCP traffic on port 6379 only from ecs-sg.

💡 Architectural Value: Even if a malicious actor manages to compromise a test EC2 instance deployed in the same private subnet, they will be categorically denied access to the database or message broker at the network layer because their instance lacks the ecs-sg identity.

## VPC Endpoints (AWS PrivateLink)

This is the most critical cost and performance optimization in the network design. For high-frequency, high-bandwidth interactions with managed AWS services, I provisioned VPC Endpoints via Terraform to bypass the NAT Gateway completely.

### Gateway Endpoints (Route Table Integrated & Free)
- Amazon S3
  - Use Case: The PySpark Inference engine continuously sinks high-volume Parquet files to the S3 data lake. The MLflow server frequently reads/writes model artifacts.

  - Value: Keeps gigabytes of streaming data entirely off the public internet and avoids NAT Gateway hourly/data processing charges.
 
### Interface Endpoints (PrivateLink)
- Amazon ECR
  - Use Case: Whenever GitHub Actions triggers a rolling update, ECS pulls 4 custom container images (Airflow, mlflow, producer and inference).

  - Value: Pulling heavy Docker images via NAT Gateway is notoriously expensive. ECR endpoints route this heavy traffic locally.
 
- CloudWatch Logs
  - Use Case: 8 distinct microservices continuously stream execution logs.
  - Value: Ensures monitoring observability without incurring egress bandwidth costs.
 
- AWS Secrets Manager
  - Use Case: ECS tasks fetch RDS passwords and API keys at startup.
  - Value: Absolute security. Credentials never traverse the NAT Gateway or public routes, eliminating the risk of man-in-the-middle interception.
- AWS Systems Manager
  - Allows secure, agent-based shell access (ECS Exec) into running containers for debugging without needing Bastion Hosts or open SSH ports.
