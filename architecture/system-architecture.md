# 🏗️ System Architecture & Data Flow

The pipeline consists of two decoupled workflows sharing a single 
MLflow model registry as the contract between training and inference.

![architecture](https://github.com/eriiinxxuu/realtime-fraud-detection-pipeline/blob/main/architecture/architecture_detail.pdf)


### Training Pipeline

**Trigger:** Airflow DAG, manually or scheduled.

**Steps:**

1. **Data ingestion** — Airflow worker reads 150,000 historical 
   transaction messages from MSK Kafka using `confluent_kafka` consumer.

2. **Feature engineering** — Flattens nested `user_profile_summary`, 
   expands `risk_signals` array into 10 binary `signal_*` columns, 
   derives time features (`hour`, `is_weekend`, `is_night`) and 
   amount features (`amount_ratio`, `is_round_amount`). Total: 26 features.

3. **Training** — LightGBM trained with `RandomizedSearchCV` 
   (n_iter=10, TimeSeriesSplit n_splits=2), optimising F-beta score 
   (β=2, recall-weighted) to minimise missed fraud.

4. **Experiment tracking** — MLflow logs hyperparameters, 
   PR-AUC, precision, recall, F1, and optimal threshold per run.

5. **Model registration** — Best model registered as 
   `fraud_detection_model` in MLflow registry. Threshold stored as 
   a MLflow metric, not hardcoded.

6. **Artifact storage** — Model binary written to 
   `s3://fraud-detection-mlflow-artifacts/` via MLflow.

**Airflow services involved:**
- `dag-processor` parses DAG files from git-sync volume → writes to RDS
- `scheduler` polls RDS → pushes tasks into ElastiCache Redis (Celery broker)
- `worker x2` consumes from Redis → executes training code
- `apiserver` reads RDS → serves Airflow UI

### Inference Pipeline

**Trigger:** ECS service starts, runs indefinitely.

**Startup sequence:**
1. Spark session initialised
2. Model loaded from MLflow registry (`models:/fraud_detection_model/latest`)
3. Threshold loaded dynamically from MLflow metric history
4. Model broadcast to all Spark executors via `SparkContext.broadcast()`

**Per micro-batch:**

1. **Consume** — Spark reads accumulated messages from MSK 
   `transactions` topic (`startingOffsets: latest`).

2. **Parse** — Raw Kafka bytes cast to string, parsed with 
   `from_json()` against a predefined schema including nested 
   `user_profile_summary` and `risk_signals` array.

3. **Feature engineering** — Same 26 features as training, 
   computed entirely in Spark using native functions 
   (`array_contains`, `hour`, `dayofweek`, `floor`, etc.). 
   No data pulled to Python driver.

4. **Inference** — `pandas_udf` receives each micro-batch as 
   a columnar Arrow batch. `predict_proba()` runs on the entire 
   batch at once — no row-by-row serialization overhead.

5. **Threshold apply** — `fraud_score >= threshold` → `fraud_pred = 1`.

6. **Filter & write** — Only `fraud_pred = 1` rows written to S3 
   as parquet, partitioned by `year / month / day / currency`. 
   Checkpoint maintained locally for exactly-once processing guarantees.


### Storage Design

| Bucket | Purpose | Lifecycle |
|---|---|---|
| `fraud-detection-mlflow-artifacts` | Model binaries, experiment metadata | 90d → STANDARD_IA |
| `fraud-detection-inference-results` | Fraud predictions (parquet) | 90d → IA → 365d → GLACIER |

Predictions partitioned by `year/month/day/currency` — Athena 
partition pruning reduces scan cost significantly for time-range queries.
