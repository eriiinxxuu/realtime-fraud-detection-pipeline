FROM python:3.10.16-slim-bookworm

#set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=UTF-8 

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    gcc g++ build-essential \
    curl \
    gnupg2 \
    python3-dev \
    libpq-dev \
    libsasl2-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*


# manully install librdkafka with SASL/SSL support
# RUN curl -fsSL https://github.com/confluentinc/confluent-kafka-python/archive/refs/tags/v2.8.0.tar.gz -o confluent-kafka.tar.gz && \
#     tar -xzf confluent-kafka.tar.gz && \
#     cd confluent-kafka-python-2.8.0 && \
#      ./configure --enable-sasl --enable-ssl && \
#     make && \
#     make install && \
#     ldconfig && \
#     cd .. && \
#     rm -rf librdkafka confluent-kafka.tar.gz



COPY ./requirements.txt /app/requirements.txt
# install python dependencies to image
RUN pip install -r /app/requirements.txt

COPY . .
ENTRYPOINT [ "python3", "main.py" ]