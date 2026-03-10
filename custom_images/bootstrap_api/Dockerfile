FROM python:3.13-slim

COPY requirements.txt /requirements.txt
COPY bootstrap_api.py /bootstrap_api.py
COPY job_definition.yaml /job_definition.yaml

RUN pip install --no-cache-dir -r requirements.txt && rm -rf /requirements.txt

ENTRYPOINT [ "uvicorn", "bootstrap_api:app", "--host", "0.0.0.0", "--port", "8000"]