import json
import os
import logging
import time
import uuid
import boto3
from dotenv import load_dotenv
from matplotlib import pyplot as plt
import mlflow
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.model_selection import TimeSeriesSplit, train_test_split
import yaml
from confluent_kafka import Consumer, KafkaException
from sklearn.preprocessing import LabelEncoder, OrdinalEncoder
import lightgbm as lgb
from sklearn.metrics import (
    average_precision_score,
    confusion_matrix,
    precision_score, 
    recall_score, 
    f1_score, 
    classification_report,
    precision_recall_curve,
    roc_auc_score
)
from imblearn.pipeline import Pipeline as ImbPipeline
from imblearn.over_sampling import SMOTE
from sklearn.model_selection import RandomizedSearchCV
from sklearn.metrics import make_scorer, fbeta_score
import lightgbm as lgb
from mlflow.models.signature import infer_signature


logging.basicConfig(
    format='%(asctime)s - %(levelname)s - %(module)s - %(message)s',
    level=logging.INFO,
    # handlers= [
    #     logging.FileHandler('./fraud_detection_model.log'),
    #     logging.StreamHandler()
    # ]
    handlers= [
    logging.StreamHandler()  
    ]

)

logger = logging.getLogger(__name__)



class FraudDetectionTraining:
    def __init__(self, config_path='/opt/airflow/dags/dags/src/config.yaml'):
        os.environ['GIT_PYTHON_REFRESH'] = 'quiet'
        os.environ['GIT_PYTHON_GIT_EXECUTABLE'] = '/usr/bin/git'

        load_dotenv(dotenv_path="/app/.env")
        self.config = self._load_config(config_path)

        # os.environ.update({
        #     'AWS_ACCESS_KEY_ID': os.getenv('AWS_ACCESS_KEY_ID'),
        #     'AWS_SECRET_ACCESS_KEY': os.getenv('AWS_SECRET_ACCESS_KEY'),
        #     'AWS_S3_ENDPOINT_URL': self.config['mlflow']['s3_endpoint_url']
        # })

        s3_endpoint_url = self.config['mlflow'].get('s3_endpoint_url')
        if s3_endpoint_url:
            os.environ['AWS_S3_ENDPOINT_URL'] = s3_endpoint_url


        self._validate_environment()
        # self._check_minio_connection()

        mlflow.set_tracking_uri(self.config['mlflow']['tracking_url'])
        mlflow.set_experiment(self.config['mlflow']['experiment_name'])
        



    def _load_config(self, config_path: str) -> dict:
        try:
            with open(config_path, 'r') as f:
                config = yaml.safe_load(f)
            logger.info('Configuration loaded successfully')
            return config

        except Exception as e:
            logger.error('Failed to load configuration: %s', str(e))
            raise e
        
    def _validate_environment(self):
        required_vars = ['KAFKA_BOOTSTRAP_SERVERS']
        missing = [var for var in required_vars if not os.getenv(var)]
        if missing:
            raise ValueError(f'Missing required environment variables: {missing}')
        

    # def _check_minio_connection(self):
    #     try:
    #         s3 = boto3.client(
    #             's3',
    #             endpoint_url = self.config['mlflow']['s3_endpoint_url'],
    #             aws_access_key_id = os.getenv('AWS_ACCESS_KEY_ID'),
    #             aws_secret_access_key =  os.getenv('AWS_SECRET_ACCESS_KEY')
    #         )

    #         buckets = s3.list_buckets()
    #         bucket_names = [b['Name'] for b in buckets.get('Buckets', [])]
    #         logger.info('MinIO connection verified. Buckets: %s', bucket_names)

    #         mlflow_bucket = self.config['mlflow'].get('bucket', 'mlflow')

    #         if mlflow_bucket not in bucket_names:
    #             s3.create_bucket(Bucket=mlflow_bucket)
    #             logger.info("Created missing MLFlow bucket %s", mlflow_bucket)

    #     except Exception as e:
    #         logger.error('MinIO connection failed: %s', str(e))
    

    # feature engineering & preprocessing
    def create_feature(self, df: pd.DataFrame) -> pd.DataFrame:
        df = df.sort_values(['user_id', 'timestamp']).copy()

        # 1. Flatten nested fields
        # user_profile_summary is a nested dict
        df['account_age_days'] = df['user_profile_summary'].apply(lambda x: x['account_age_days'])
        df['is_frequent_traveler'] = df['user_profile_summary'].apply(lambda x: x['is_frequent_traveler'])
        df['avg_transaction'] = df['user_profile_summary'].apply(lambda x: x['avg_transaction'])
        df['home_country'] = df['user_profile_summary'].apply(lambda x: x['home_country'])

        # 2. Handle risk_signals list
        all_signals = ['amount_anomaly_3x', 
                       'amount_anomaly_5x', 
                       'geo_anomaly', 
                       'high_risk_merchant',
                       'velocity_10min_high',
                       'velocity_1h_high',
                       'device_change',
                       'night_transaction',
                       'new_account',
                       'high_risk_mcc']

        for signal in all_signals:
            df[f'signal_{signal}'] = df['risk_signals'].apply(lambda x: 1 if signal in x else 0)

        # 3. Time features
        df['timestamp'] = pd.to_datetime(df['timestamp'])
        df['hour'] = df['timestamp'].dt.hour
        df['day_of_week'] = df['timestamp'].dt.dayofweek
        df['is_weekend'] = df['day_of_week'].isin([6, 7]).astype(int)
        df['is_night'] = ((df['hour'] >= 21) | (df['hour'] < 5)).astype(int)
    
        # 4. Derived features
        df['amount_ratio'] = df['amount'] / df['avg_transaction'].replace(0, 1)
        df['is_home_country'] = (df['location'] == df['home_country']).astype(int)
        df['is_small_amount'] = (df['amount'] < 5).astype(int)  # Card testing often uses small amounts
        df['is_round_amount'] = (df['amount'] % 1 == 0).astype(int)


        # Drop columns not needed for training
        drop_cols = [
            'transaction_id',
            'user_id', 
            'fraud_type',        # Label leakage
            'fraud_details',     # Label leakage
            'risk_signals',      # Already flattened
            'risk_score',
            'user_profile_summary',  # Already flattened
            'home_country',      # Used for is_home_country
        ]
        df = df.drop(columns=drop_cols, errors='ignore')

        if 'is_fraud' not in df.columns:
            raise ValueError('Missing target column "is_fraud"')
        
        return df
    


    def read_from_kafka(self,max_messages: int = 200000, timeout_minutes: int = 5) -> pd.DataFrame:
        try:
            # topic = os.getenv('KAFKA_TOPIC')
            topic = os.getenv('KAFKA_TOPIC') or self.config['kafka']['topic']
            logger.info('Connecting to Kafka topic %s', topic)

            # consumer_config = {
            #     'bootstrap.servers': os.getenv('KAFKA_BOOTSTRAP_SERVERS'),
            #     'security.protocol': 'SASL_SSL',
            #     'sasl.mechanisms': 'PLAIN',
            #     'sasl.username': os.getenv('KAFKA_USERNAME'),
            #     'sasl.password':os.getenv('KAFKA_PASSWORD'),
            #     'group.id': f'training_{uuid.uuid4().hex[:8]}',
            #     'auto.offset.reset': 'earliest'
            # }
            kafka_username = os.getenv('KAFKA_USERNAME')
            kafka_password = os.getenv('KAFKA_PASSWORD')

            consumer_config = {
                'bootstrap.servers': os.getenv('KAFKA_BOOTSTRAP_SERVERS'),
                'security.protocol': 'SASL_SSL' if kafka_username and kafka_password else 'PLAINTEXT',
                'group.id': f'training_{uuid.uuid4().hex[:8]}',
                'auto.offset.reset': 'earliest'
            }

            if kafka_username and kafka_password:
                consumer_config['sasl.mechanisms'] = 'PLAIN'
                consumer_config['sasl.username'] = kafka_username
                consumer_config['sasl.password'] = kafka_password

            consumer = Consumer(consumer_config)
            consumer.subscribe([topic])

            

            messages = []
            start_time = time.time()
            timeout_seconds = timeout_minutes * 60

            while len(messages) < max_messages:
                if time.time() - start_time > timeout_seconds:
                    logger.info('Timeout reached after %d minutes', timeout_minutes)
                    break

                msg = consumer.poll(1.0)
                if msg is None:
                    continue

                if msg.error():
                    logger.error('Consumer error: %s', msg.error())
                    continue

                data = json.loads(msg.value().decode('utf-8'))
                messages.append(data)

            consumer.close()
            df = pd.DataFrame(messages)

            if df.empty:
                raise ValueError('No messages received from Kafka')
            
            df['timestamp'] = pd.to_datetime(df['timestamp'], format='ISO8601')

            # percentage of fraudulent transactions
            fraud_rate = df['is_fraud'].mean()*100
            logger.info(f'Kafka data read successfully with fraud rate: {round(fraud_rate,2)}%')
            return df
        
        except Exception as e:
            logger.error('Failed to read data from kafka: %s', str(e), exc_info=True)
            raise e
        
        
    def train_model(self):
         
        # 1. read data from Kafka
        # 2. feature engineering
        # 3. split data into train(80%) and test(20%) data
        # 4. log model and artifacts in MLflow
        # 5. pre-processing pipeline: encode
        # 6. tune parameters: randomized search CV
        try:
            logger.info('Starting model training process')
            
            # read raw data from Kafka
            df = self.read_from_kafka()

             # start feature engineering from the raw data
            data = self.create_feature(df)

            
            if data['is_fraud'].sum() == 0:
                raise ValueError('No positive samples in training data')
             
            data = data.sort_values('timestamp')
            split_idx = int(len(data) * 0.8)
            
            train_data = data.iloc[:split_idx]
            test_data = data.iloc[split_idx:]
            
    
            x_train = train_data.drop(columns=['is_fraud', 'timestamp'])
            y_train = train_data['is_fraud']
            x_test = test_data.drop(columns=['is_fraud', 'timestamp'])
            y_test = test_data['is_fraud']

            with mlflow.start_run():
                mlflow.log_metrics({
                    'train_samples': x_train.shape[0],
                    'positive_samples': int(y_train.sum()),
                    'class_ratio': float(y_train.mean()),
                    'test_samples': x_test.shape[0]
                })
                categorical_cols = ['currency', 'merchant', 'location', 'mcc', 'device_id']
                preprocessor = ColumnTransformer(
                        transformers=[
                            ('cat_encoder', OrdinalEncoder(
                                handle_unknown='use_encoded_value',
                                unknown_value=-1,
                                dtype=np.float32
                            ), categorical_cols)
                        ],
                        remainder='passthrough'
                    )
            
                scale = (y_train == 0).sum() / (y_train == 1).sum()

                lgbm = lgb.LGBMClassifier(
                
                    n_estimators=self.config['model']['params']['n_estimators'],       
                    # max_depth=self.config['model']['params']['max_depth'],             
                    # num_leaves=self.config['model']['params']['num_leaves'],              
                    # learning_rate=self.config['model']['params']['learning_rate'],           
                    
                    # scale_pos_weight=scale,
                    
                    # min_child_samples=self.config['model']['params']['min_child_samples'],     
                    # reg_alpha=self.config['model']['params']['reg_alpha'],              
                    # reg_lambda=self.config['model']['params']['reg_lambda'],             
                    # subsample=self.config['model']['params']['subsample'],              
                    # colsample_bytree=self.config['model']['params']['colsample_bytree'],     
                    
                    # metric='auc',
                    random_state=self.config['model']['params'].get('seed', 42),
                    n_jobs=-1,
                    verbose=-1
                )

                # --- pipeline construction ---
                # Pipeline

                pipeline = ImbPipeline(steps=[
                    ('preprocessor', preprocessor),
                    ('smote', SMOTE(random_state=self.config['model'].get('seed', 42))),
                    ('classifier', lgbm)
                ], memory='./cache')

                # Parameter distribution for LightGBM
                param_dist = {
                    'classifier__max_depth': [4, 6, 8, 10],
                    'classifier__num_leaves': [31, 63, 127],
                    'classifier__learning_rate': [0.01, 0.05, 0.1],
                    'classifier__subsample': [0.6, 0.8, 1.0],
                    'classifier__colsample_bytree': [0.6, 0.8, 1.0],
                    'classifier__reg_alpha': [0, 0.1, 0.5],
                    'classifier__reg_lambda': [0, 0.1, 0.5],
                    'classifier__min_child_samples': [50, 100, 200],
                }

                searcher = RandomizedSearchCV(
                    pipeline,
                    param_dist,
                    n_iter=20,
                    scoring=make_scorer(fbeta_score, beta=2, zero_division=0),
                    cv=TimeSeriesSplit(n_splits=3), 
                    random_state=42,
                    n_jobs=-1,
                    verbose=2
                )

                logger.info('Starting hyperparameter tuning...')

                searcher.fit(x_train, y_train)
                
                # Best results
                best_model = searcher.best_estimator_
                best_params = searcher.best_params_
                logger.info('Best hyperparameters: %s', best_params)

                test_proba = best_model.predict_proba(x_test)[:,1]
                precision_arr, recall_arr, threshold_arr = precision_recall_curve(y_test, test_proba)

                f1_arr = [2*(p*r)/(p+r) if (p+r) > 0 else 0 for p, r in zip(precision_arr[:-1], recall_arr[:-1])]
                best_threshold = threshold_arr[np.argmax(f1_arr)]
                logger.info('Optimal threshold determined: %.4f', best_threshold)


                y_pred = (test_proba >= best_threshold).astype(int)

                metrics = {
                    'auc_pr': float(average_precision_score(y_test, test_proba)),
                    'precision': float(precision_score(y_test, y_pred, zero_division=0)),
                    'recall': float(recall_score(y_test, y_pred, zero_division=0)),
                    'f1': float(f1_score(y_test, y_pred, zero_division=0)),
                    'threshold': float(best_threshold)
                }

                mlflow.log_metrics(metrics)
                mlflow.log_params(best_params)

                # Feature importance
                lgbm_model = best_model.named_steps['classifier']
                preprocessor_fitted = best_model.named_steps['preprocessor']
                
                cat_features = list(preprocessor_fitted.transformers_[0][2])
                num_features = [c for c in x_train.columns if c not in cat_features]
                feature_names = cat_features + num_features

                importance_df = pd.DataFrame({
                    'feature': feature_names,
                    'importance': lgbm_model.feature_importances_
                }).sort_values('importance', ascending=False)

                # Log feature importance to MLflow
                importance_df.to_csv('feature_importance.csv', index=False)
                mlflow.log_artifact('feature_importance.csv')

                # Log top 10 feature importance as metrics
                importance_metrics = {
                    f"imp_{row['feature'][:20]}": float(row['importance'])
                    for _, row in importance_df.head(10).iterrows()
                }
                mlflow.log_metrics(importance_metrics)

                logger.info('Top 10 features:\n%s', importance_df.head(10).to_string())

                # Feature importance plot
                plt.figure(figsize=(10, 8))
                top_features = importance_df.head(15)
                plt.barh(top_features['feature'], top_features['importance'])
                plt.xlabel('Importance')
                plt.title('Top 15 Feature Importance')
                plt.gca().invert_yaxis()
                plt.tight_layout()
                plt.savefig('feature_importance.png')
                mlflow.log_artifact('feature_importance.png')
                plt.close()

                # confusion metrix
                cm = confusion_matrix(y_test, y_pred)
                plt.figure(figsize=(6,4))
                plt.imshow(cm, interpolation='nearest', cmap=plt.cm.Blues)
                plt.title('Confusion Matrix')
                plt.colorbar()
                tick_marks = np.arange(2)
                plt.xticks(tick_marks, ['Not Fraud','Fraud'])
                plt.yticks(tick_marks, ['Not Fraud','Fraud'])

                for i in range(2):
                    for j in range(2):
                        plt.text(j, i, format(cm[i,j], 'd'), ha = 'center', va = 'center', color = 'red')
                
                plt.tight_layout()
                cm_filename = 'confusion_matrix.png'
                plt.savefig(cm_filename)

                mlflow.log_artifact(cm_filename)
                plt.close()

                # precision and recall curve
                plt.figure(figsize=(10,6))
                plt.plot(recall_arr, precision_arr, marker = '.', label='Precision-Recall Curve')
                plt.xlabel('Recall')
                plt.ylabel('Precision')
                plt.title('Precision-Recall Curve')
                plt.legend()
                pr_filename= 'Precision_Recall_Curve.png'
                plt.savefig(pr_filename)
                mlflow.log_artifact(pr_filename)
                plt.close()

                signature = infer_signature(x_train, y_pred)
                input_example = x_train.head(5) 

                mlflow.sklearn.log_model(
                    sk_model=best_model,
                    artifact_path='model',
                    signature=signature,
                    input_example=input_example,
                    registered_model_name='fraud_detection_model'
                )
                # os.makedirs('/app/models', exist_ok=True)
                # mlflow.log_artifact('/app/models/fraud_detection_model.pkl')

                logger.info('Training successfully completed with metrics: %s', metrics)
                return best_model, metrics

        except Exception as e:
            logger.error('Training failed: %s', str(e), exc_info=True)
            raise
            
            


