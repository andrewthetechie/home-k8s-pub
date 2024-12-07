from python:3.13-slim

COPY requirements.txt /requirements.txt
COPY autoinstall_generator.py /autoinstall_generator.py
COPY entrypoint.sh /entrypoint.sh

RUN pip install --no-cache-dir -r requirements.txt && rm -rf /requirements.txt && chmod +x /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]