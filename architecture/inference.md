## PySpark Vectorization & Inference Optimization

### The Problem: Python UDF Serialization Overhead

Spark runs on the JVM. When Python code needs to process data,
every row must cross the JVM ↔ Python boundary:
```
JVM (Spark executor)
    │ serialize row 1 → pickle
    ▼
Python process
    │ deserialize → process → serialize result → pickle
    ▼
JVM
    │ deserialize result
    ▼
... repeat for every row
```

For 100,000 rows, this means 100,000 serialization round-trips.
With a LightGBM model, the overhead of crossing this boundary
dwarfs the actual prediction time.

---

### Solution: pandas_udf with Apache Arrow

`pandas_udf` replaces row-by-row serialization with a single
columnar transfer per micro-batch using **Apache Arrow**:
```
JVM (Spark executor)
    │ serialize entire micro-batch as Arrow columnar format
    ▼
Python process
    │ deserialize once → pd.DataFrame (26 feature columns)
    │ model.predict_proba(entire_batch)  ← one call, all rows
    │ return pd.Series of scores
    ▼
JVM
    │ deserialize once
```

**Serialization round-trips:**
- Regular UDF: `n_rows` round-trips
- `pandas_udf`: `1` round-trip per micro-batch

---

### Implementation
```python
@pandas_udf(DoubleType())
def predict_proba_udf(*cols: pd.Series) -> pd.Series:
    model = broadcast_model.value          # retrieve from broadcast
    input_df = pd.concat(cols, axis=1)     # stack 26 Series → DataFrame
    input_df.columns = feature_cols        # assign column names
    proba = model.predict_proba(input_df)[:, 1]  # batch inference
    return pd.Series(proba.astype("float64"))
```

**`*cols: pd.Series`** — Spark passes each feature column as a
separate `pd.Series`. All rows in the current micro-batch are
included. `pd.concat(cols, axis=1)` assembles them horizontally
into the full feature matrix.

**`model.predict_proba(input_df)`** — LightGBM operates on the
entire DataFrame at once. Internally this is a C++ matrix
operation — vectorized, not looped.

**`[:, 1]`** — takes the positive class (fraud) probability
column from the `(n_rows, 2)` output array.

---

### Broadcast Variable — Zero-Copy Model Distribution

Without broadcast, every Spark task would need to fetch the
LightGBM model independently:
```
Without broadcast:
task 1 → load model from MLflow (network I/O)
task 2 → load model from MLflow (network I/O)
task 3 → load model from MLflow (network I/O)
... repeated for every task in every micro-batch
```

With broadcast:
```
Driver startup:
    model = mlflow.sklearn.load_model("models:/fraud_detection_model/latest")
    broadcast_model = spark.sparkContext.broadcast(model)
    # model serialised once, sent to each executor once
    # cached in executor memory for the lifetime of the job

Per micro-batch:
task 1 → broadcast_model.value  ← in-memory, zero network I/O
task 2 → broadcast_model.value  ← same
task 3 → broadcast_model.value  ← same
```
```python
# Driver — runs once at startup
self.model = self._load_model()
self.broadcast_model = self.spark.sparkContext.broadcast(self.model)

# Inside pandas_udf — runs on executor, per micro-batch
model = broadcast_model.value
```

The model is loaded exactly **once** from MLflow at startup,
broadcast to all executors, and reused across all micro-batches
for the lifetime of the streaming job.

---

### Feature Engineering in Spark — No Python Driver Involvement

All 26 features are computed using **Spark native functions**,
meaning the data never leaves the JVM during feature engineering:
```python
# Flatten nested struct — no Python loop
df.withColumn("account_age_days",
    col("user_profile_summary.account_age_days"))

# Array expansion — vectorised in JVM
df.withColumn(f"signal_{s}",
    array_contains(col("risk_signals"), lit(s)).cast("int"))

# Time features — JVM-side date functions
df.withColumn("hour", hour(col("event_time")))
df.withColumn("is_weekend",
    when(col("day_of_week").isin([1, 7]), 1).otherwise(0))

# Derived features — JVM arithmetic
df.withColumn("amount_ratio",
    col("amount") / when(col("avg_transaction") == 0, 1.0)
                    .otherwise(col("avg_transaction")))
```

The JVM → Python boundary is crossed **exactly once** per
micro-batch: when the fully-engineered feature matrix is
handed to `pandas_udf` for LightGBM inference.

---

### End-to-End Per Micro-batch Flow
```
Kafka (MSK)
    │ accumulated messages since last batch
    ▼
Spark readStream (JVM)
    │ CAST value AS STRING
    │ from_json() → structured DataFrame
    │ 26 feature columns computed natively in JVM
    ▼
pandas_udf boundary (JVM → Python, Arrow, once)
    │ pd.concat(cols, axis=1) → feature matrix
    │ broadcast_model.predict_proba(batch) → fraud scores
    │ return pd.Series
    ▼
Spark (JVM)
    │ fraud_score >= threshold → fraud_pred = 1
    │ filter(fraud_pred == 1)
    ▼
S3 writeStream
    │ parquet, partitioned by year/month/day/currency
    │ checkpoint for exactly-once guarantees
```

---

### Spark Configuration
```yaml
# config.yaml
spark:
  app_name: "FraudDetectionInference"
  shuffle_partition: 2   # low partition count for single-node ECS task
```
```
# spark-submit
--conf spark.sql.shuffle.partitions=2
```

`shuffle_partitions=2` is intentionally low — the inference
service runs as a single ECS task (4 vCPU / 8 GB). The default
of 200 shuffle partitions would create unnecessary overhead
for the data volumes processed here.
