# build image
FROM python:3.10.16-slim-bookworm
WORKDIR /app
COPY mlflow/requirements.txt /app/requirements.txt

RUN pip install -r/app/requirements.txt

# copy the rest of the application

COPY mlflow/ .

EXPOSE 5500

CMD ["sh", "-c", "mlflow server --host 0.0.0.0 --port 5500 --backend-store-uri $MLFLOW_DB_URL --default-artifact-root s3://$MLFLOW_ARTIFACT_BUCKET/ --allowed-hosts *"]
