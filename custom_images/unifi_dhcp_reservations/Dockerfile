from python:3.13-slim

COPY requirements.txt /requirements.txt
COPY ip_reservation_google_sheet.py /ip_reservation_google_sheet.py
COPY entrypoint.sh /entrypoint.sh

RUN pip install --no-cache-dir -r requirements.txt && rm -rf /requirements.txt && chmod +x /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]