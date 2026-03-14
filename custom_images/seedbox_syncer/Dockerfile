FROM python:3.12-alpine

RUN apk add --no-cache rsync openssh-client

COPY requirements.txt /requirements.txt
RUN pip install --no-cache-dir -r /requirements.txt

COPY sync_media.py /sync_media.py

ENTRYPOINT ["python3", "/sync_media.py"]
