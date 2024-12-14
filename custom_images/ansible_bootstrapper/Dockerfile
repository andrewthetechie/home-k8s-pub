from python:3.13-slim

COPY hosts /hosts
COPY requirements.txt /requirements.txt
COPY entrypoint.sh /entrypoint.sh
COPY make_inventory.py /make_inventory.py

RUN apt-get update && apt-get install -y make git && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir -r requirements.txt && rm -rf /requirements.txt && chmod +x /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]