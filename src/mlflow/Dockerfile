# build image
FROM python:3.10.16-slim-bookworm
WORKDIR /app
COPY requirements.txt /app/requirements.txt


RUN pip install -r/app/requirements.txt

# copy the rest of the application
COPY . .

EXPOSE 5500
