from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.standard.operators.python import PythonOperator
from airflow.providers.standard.operators.bash import BashOperator
from airflow.exceptions import AirflowException
import logging


logger = logging.getLogger(__name__)

default_args = {
    'owner': 'Erin_Xu_FraudDetection',
    'depends_on_past': False,
    'start_date': datetime(2026, 3, 13),
    'email_on_failure': False,
    'execution_timeout': timedelta(minutes=180),
    'retries': 1,
    'retry_delay': timedelta(minutes=5)
}


def _train_model(**context):
    from fraud_detection_training import FraudDetectionTraining
    try:
        logger.info('Initializing fraud detection training')
        trainer = FraudDetectionTraining()
        model, precision = trainer.train_model()
        
        return {'status': 'success', 'precision': precision}
    except Exception as e:
        logger.error('Training failed: %s', str(e), exc_info=True)
        raise AirflowException(f'Model training failed {str(e)}')

with DAG(
    'fraud_detection_training',
    default_args=default_args,
    description='Fraud detection model training pipeline',
    schedule='0 3 * * *', # run at 3AM everyday
    catchup=False,
    tags=['fraud', 'ML']
) as dag:
    
    # validate_env = BashOperator(
    #     task_id = 'validate_environment',
    #     bash_command = '''
    #     echo "Validating Environment..."
    #     test -f /app/config.yaml &&
    #     # test -f /app/.env &&
    #     echo "Environment is valid!" 
    #     '''
    # )

    validate_env = BashOperator(
    task_id = 'validate_environment',
    bash_command = '''
    echo "Validating Environment..."
    test -f /opt/airflow/dags/dags/src/config.yaml &&
    echo "Environment is valid!" 
    '''
    )


    training_task = PythonOperator(
        task_id='model_training',
        python_callable=_train_model
        )

    cleanup_task = BashOperator(
        task_id = 'cleanup_resources',
        bash_command = 'rm -f /app/tmp/*.pkl',
        trigger_rule='all_done'
    )

    validate_env >> training_task >> cleanup_task


    # Documentation

    dag.doc_md = """

    ## Fraud Detection Training Pipeline

    Daily training of fraud detection model using:
    - Transaction data from Kafka
    - XGBoost classifier with precision optimisation
    - MLFlow for experimental tracking

    """