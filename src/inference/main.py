import os
import pickle
from dotenv import load_dotenv
import mlflow
from pyspark.sql import SparkSession
import logging
from pyspark.sql.types import (
    StructType, StructField, StringType, IntegerType, 
    DoubleType, BooleanType, ArrayType, TimestampType
)
from pyspark.sql.functions import (
    col, lit, array_contains,from_json,
    hour, dayofweek, when, floor, to_timestamp, pandas_udf,
    struct, to_json
)
import yaml
import pandas as pd

logging.basicConfig(
    format='%(asctime)s - %(levelname)s - %(module)s - %(message)s',
    level=logging.INFO
)

logger = logging.getLogger(__name__)

class FraudDetectionInference:
    bootstrap_servers = None
    topic = None
    security_protocol = None
    sasl_mechanism = None
    username = None
    password = None
    sasl_jaa_config = None

    FEATURE_COLUMNS = [
        # categorical (raw strings)
        "currency", "merchant", "location", "mcc", "device_id",

        # numeric / boolean
        "amount",
        "account_age_days", "is_frequent_traveler", "avg_transaction",
        "hour", "day_of_week", "is_weekend", "is_night",
        "amount_ratio", "is_home_country", "is_small_amount", "is_round_amount",

        # signal_*
        "signal_amount_anomaly_3x",
        "signal_amount_anomaly_5x",
        "signal_geo_anomaly",
        "signal_high_risk_merchant",
        "signal_velocity_10min_high",
        "signal_velocity_1h_high",
        "signal_device_change",
        "signal_night_transaction",
        "signal_new_account",
        "signal_high_risk_mcc",
        ]

    ALL_SIGNALS = [
        "amount_anomaly_3x",
        "amount_anomaly_5x",
        "geo_anomaly",
        "high_risk_merchant",
        "velocity_10min_high",
        "velocity_1h_high",
        "device_change",
        "night_transaction",
        "new_account",
        "high_risk_mcc",
        ]

    def __init__(self, config_path='/opt/airflow/dags/dags/src/config.yaml'):
        load_dotenv(dotenv_path='/app/.env')
        self.config = self._load_config(config_path)
        self.spark = self._init_spark_session()
        self.model = self._load_model()
        self.broadcast_model = self.spark.sparkContext.broadcast(self.model)
        logger.debug('Enviornment variables loaded: %s', dict(os.environ))
        

    import mlflow

    def _load_model(self):
        mlflow.set_tracking_uri(self.config['mlflow']['tracking_url'])
        model = mlflow.sklearn.load_model("models:/fraud_detection_model/latest")
        logger.info('Model loaded from MLflow')
        return model


    @staticmethod
    def _load_config(config_path):
        try:
            with open(config_path, 'r') as f:
                return yaml.safe_load(f)
        except Exception as e:
            logger.error(f'Error loading config: {str(e)}')
            raise


    def _init_spark_session(self):
        try:
            packages = self.config.get('spark', {}).get('packages', '')
            builder = SparkSession.builder.appName(
                self.config.get('spark').get('app_name')
            )

            if packages:
                builder = builder.config('spark.jars.packages', packages)
            spark = builder.getOrCreate()
            logger.info("Spark Session initialised")
            return spark 

        except Exception as e:
            logger.error(
                'Error initialising spark session: %s',
                str(e)
            )
            raise

    def read_from_kafka(self):
        logger.info(f"Reading data from Kafka {self.config['kafka']['topic']}")
        kafka_bootstrap_server = os.getenv('KAFKA_BOOTSTRAP_SERVERS')
        kafka_topic = os.getenv('KAFKA_TOPIC')
        kafka_security_protocol = self.config['kafka']['security_protocol']
        kafka_sasl_mechanism = self.config['kafka']['sasl_mechanism']
        kafka_username = os.getenv("KAFKA_USERNAME")
        kafka_password = os.getenv("KAFKA_PASSWORD")
        # kafka_sasl_jaas_config = (
        #     f'org.apache.kafka.common.security.plain.PlainLoginModule required '
        #     f'username="{kafka_username}" password="{kafka_password}";'
        # )

        self.bootstrap_servers = kafka_bootstrap_server
        self.topic = kafka_topic
        self.security_protocol = kafka_security_protocol
        self.sasl_mechanism = kafka_sasl_mechanism
        self.username = kafka_username
        self.password = kafka_password
        # self.sasl_jaa_config = kafka_sasl_jaas_config

        kafka_options = {
        'kafka.bootstrap.servers': kafka_bootstrap_server,
        'subscribe': kafka_topic,
        'startingOffsets': 'latest',
        'kafka.security.protocol': kafka_security_protocol,
    }


        # df = (self.spark.readStream
              
        #       .format('kafka')
        #       .option('kafka.bootstrap.servers', kafka_bootstrap_server)
        #       .option('subscribe', kafka_topic)
        #       .option('startingOffsets', 'latest')
        #       .option("kafka.security.protocol", kafka_security_protocol)
        #       .option("kafka.sasl.mechanism", kafka_sasl_mechanism)
        #       .option("kafka.sasl.jaas.config", kafka_sasl_jaas_config)
        #       .load()
        # )
        # Only add SASL config if needed
        if kafka_sasl_mechanism:
            kafka_sasl_jaas_config = (
                f'org.apache.kafka.common.security.plain.PlainLoginModule required '
                f'username="{kafka_username}" password="{kafka_password}";'
                )
            kafka_options['kafka.sasl.mechanism'] = kafka_sasl_mechanism
            kafka_options['kafka.sasl.jaas.config'] = kafka_sasl_jaas_config
            self.sasl_jaa_config = kafka_sasl_jaas_config
        else:
            self.sasl_jaa_config = None

        df = self.spark.readStream.format('kafka')
        for key, value in kafka_options.items():
            df = df.option(key, value)
        df = df.load()

        json_schema = StructType([

            StructField("transaction_id", StringType(), True),
            StructField("user_id", IntegerType(), True),
            StructField("amount", DoubleType(), True),
            StructField("currency", StringType(), True),
            StructField("timestamp", StringType(), True),

            StructField("merchant", StringType(), True),
            StructField("location", StringType(), True),
            StructField("device_id", StringType(), True),
            StructField("mcc", StringType(), True),
            StructField("risk_signals", ArrayType(StringType()), True),
            StructField(
                "user_profile_summary",
                StructType([
                    StructField("account_age_days", IntegerType(), True),
                    StructField("is_frequent_traveler", BooleanType(), True),
                    StructField("avg_transaction", DoubleType(), True),
                    StructField("home_country", StringType(), True),
                ]),
                True
            )
        ])

        parsed_df = (df.selectExpr("CAST(value AS STRING) AS value")
                     .select(from_json(col('value'), json_schema).alias('data'))
                     .select('data.*')
                     )
        return parsed_df



    def add_features(self, df):

        df = df.withColumn("event_time", col("timestamp").cast("timestamp"))

        #  flatten user_profile_summary
        df = (
            df
            .withColumn("account_age_days", col("user_profile_summary.account_age_days"))
            .withColumn("is_frequent_traveler", col("user_profile_summary.is_frequent_traveler").cast("int"))
            .withColumn("avg_transaction", col("user_profile_summary.avg_transaction"))
            .withColumn("home_country", col("user_profile_summary.home_country"))
        )

        #  risk_signals -> signal_*
        for s in self.ALL_SIGNALS:
            df = df.withColumn(f"signal_{s}", array_contains(col("risk_signals"), lit(s)).cast("int"))

        #  time features
        df = (
            df
            .withColumn("hour", hour(col("event_time")))
            .withColumn("day_of_week", dayofweek(col("event_time")))  # 1=Sun ... 7=Sat
            .withColumn("is_weekend", when(col("day_of_week").isin([1, 7]), lit(1)).otherwise(lit(0)))
            .withColumn("is_night", when((col("hour") >= 21) | (col("hour") < 5), lit(1)).otherwise(lit(0)))
        )

        #  derived features
        df = (
            df
            .withColumn("amount_ratio", col("amount") / when(col("avg_transaction") == 0, lit(1.0)).otherwise(col("avg_transaction")))
            .withColumn("is_home_country", (col("location") == col("home_country")).cast("int"))
            .withColumn("is_small_amount", (col("amount") < 5).cast("int"))
            .withColumn("is_round_amount", (floor(col("amount")) == col("amount")).cast("int"))
        )
        return df
    
    def run_inference(self):
        df = self.read_from_kafka()
        df = self.add_features(df)

        broadcast_model = self.broadcast_model
        feature_cols = self.FEATURE_COLUMNS

         #lastest model
        threshold = 0.7
       

        @pandas_udf(DoubleType())
        def predict_proba_udf(*cols: pd.Series) -> pd.Series:
            model = broadcast_model.value
            input_df = pd.concat(cols, axis=1)
            input_df.columns = feature_cols
            proba = model.predict_proba(input_df)[:, 1]
            return pd.Series(proba.astype("float64"))

        scored_df = (
            df.withColumn("fraud_score", predict_proba_udf(*[col(c) for c in feature_cols]))
            .withColumn("fraud_pred", when(col("fraud_score") >= lit(threshold), lit(1)).otherwise(lit(0)))
        )

        fraud_prediction = scored_df.filter(col('fraud_pred') == 1)
        output_df = fraud_prediction.selectExpr(
        "CAST(transaction_id AS STRING) AS key",
        "to_json(struct(*)) AS value"
        )

    #     query = (
    #     output_df.writeStream
    #     .format("kafka")
    #     .option('kafka.bootstrap.servers', self.bootstrap_servers)
    #     .option('topic', 'fraud_predictions_output')
    #     .option('kafka.security.protocol', self.security_protocol)
    #     .option('kafka.sasl.mechanism', self.sasl_mechanism)
    #     .option("kafka.sasl.jaas.config", self.sasl_jaa_config)
    #     .option('checkpointLocation', 'checkpoints/checkpoint')
    #     .outputMode('append')
    #     .start()
    # )
    #     query.awaitTermination()
        write_options = {
        'kafka.bootstrap.servers': self.bootstrap_servers,
        'topic': 'fraud_predictions_output',
        'kafka.security.protocol': self.security_protocol,
        'checkpointLocation': 'checkpoints/checkpoint',
    }

        if self.sasl_jaa_config:
            write_options['kafka.sasl.mechanism'] = self.sasl_mechanism
            write_options['kafka.sasl.jaas.config'] = self.sasl_jaa_config

        query = output_df.writeStream.format('kafka')
        for key, value in write_options.items():
            query = query.option(key, value)
        query = query.outputMode('append').start()
        query.awaitTermination()



if __name__ == "__main__":
    inference = FraudDetectionInference('/app/config.yaml')
    inference.run_inference()