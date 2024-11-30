FROM python:3.14.0a1-slim

COPY driver_transformer driver_transformer
WORKDIR driver_transformer
RUN pip install --upgrade pip
RUN pip install -e .
ENTRYPOINT ["python", "-m", "driver_transformer"]
