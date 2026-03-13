# build image
FROM apache/airflow:3.1.6


# create models directory and set ownership
USER root

RUN apt-get update && apt-get install -y \
    libgomp1 \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*
    

RUN mkdir -p /app/models && chown -R airflow:0 /app

COPY airflow/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh


# switch back to airflow user for safety
USER airflow
COPY airflow/requirements.txt /tmp/requirements.txt

# install Python packages as root
RUN pip install -r /tmp/requirements.txt


ENTRYPOINT ["/entrypoint.sh"]
CMD []