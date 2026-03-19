## Airflow ECS Orchestration & Microservices

### Service Decomposition

Airflow runs as **5 independent ECS Fargate services**, each 
containerised separately rather than co-located in a single container.
This mirrors the official Airflow distributed architecture and allows
each component to scale, restart, and fail independently.

| Service | vCPU | Memory | Role |
|---|---|---|---|
| `airflow-apiserver` | 0.5 | 1 GB | Serves Airflow UI and REST API |
| `airflow-scheduler` | 0.5 | 1 GB | Polls RDS, triggers task execution |
| `airflow-dag-processor` | 0.5 | 1 GB | Parses DAG files, writes metadata to RDS |
| `airflow-triggerer` | 0.5 | 1 GB | Handles async sensors |
| `airflow-worker` x2 | 4 | 8 GB | Executes task code (training, feature engineering) |

Workers are allocated 4 vCPU / 8 GB because they run the actual 
LightGBM training — the most compute-intensive step in the pipeline.
All services run on **ARM64** (Graviton) for cost efficiency.

---

### CeleryExecutor Communication Flow

Airflow uses **CeleryExecutor** with ElastiCache Redis as the 
message broker and RDS PostgreSQL as the result backend and 
metadata store.
```
dag-processor
    │ parses DAG .py files from shared volume
    │ writes DAG structure + task definitions
    ▼
RDS PostgreSQL (metadata store)
    │ scheduler polls: "is it time to run?"
    ▼
scheduler
    │ marks task_instance as QUEUED
    │ pushes task to Redis
    ▼
ElastiCache Redis (Celery broker)
    │ worker picks up task
    ▼
worker x2
    │ executes DAG task code
    │ writes task_instance state (SUCCESS/FAILED) back to RDS
    │ writes Celery result backend to RDS
    ▼
RDS PostgreSQL
    │ apiserver reads task states
    ▼
apiserver (Airflow UI)
```

Key point: **no direct service-to-service communication**. 
RDS is the single source of truth for all task states. 
The apiserver never talks directly to workers — it only reads RDS.

---

### DAG Synchronisation — git-sync Sidecar Pattern

Each Airflow service runs **two containers** within the same ECS task:
```
ECS Task (e.g. airflow-worker)
├── main container     — executes Airflow logic
└── git-sync container — pulls DAGs from GitHub every 60s
```

Both containers share a single `emptyDir` volume (`dags-git`):
```
git-sync container:
  GITSYNC_ROOT  = /data/git       ← volume mount point
  GITSYNC_LINK  = dags            ← creates symlink: /data/git/dags → repo root
  GITSYNC_REPO  = github.com/...
  GITSYNC_PERIOD = 60s

Airflow main container:
  /opt/airflow/dags               ← same volume, different mount path
  = /data/git/dags/src/dags/      ← where actual DAG .py files live
```

`AIRFLOW__CORE__DAGS_FOLDER` is set to 
`/opt/airflow/dags/dags/src/dags` to point Airflow at the correct 
subdirectory within the synced repo.

**Why git-sync instead of baking DAGs into the image:**
- DAG changes take effect within 60 seconds — no image rebuild or
  redeployment required
- DAG code and infrastructure code are versioned separately
- All 5 Airflow services always run the same DAG version simultaneously

**Trade-off:** 5 independent git-sync containers each pull from 
GitHub independently, because ECS `emptyDir` volumes are 
task-scoped and cannot be shared across tasks. This is the cost 
of not using EFS.

---

---

### Secrets Management

All credentials injected at runtime via **AWS Secrets Manager** — 
never stored in environment variables or Docker images:

| Secret | Used by |
|---|---|
| `airflow/db-url` | Airflow services → RDS |
| `mlflow/db-url` | MLflow server → RDS |
| `airflow/celery-result-backend` | Workers → RDS |
| `fraud-detection/redis/broker-url` | Scheduler, workers → Redis |
| `fraud-detection/msk/bootstrap-servers` | Producer, inference → MSK |
| `airflow/jwt-secret` | Airflow API authentication |

ECS task execution role has `secretsmanager:GetSecretValue` 
permission scoped to only these specific secret ARNs.
