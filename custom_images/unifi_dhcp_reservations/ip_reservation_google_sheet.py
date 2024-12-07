import gspread
from oauth2client.service_account import ServiceAccountCredentials
import requests
import os
import urllib3

urllib3.disable_warnings()

# Unifi Controller Information
controller_url = os.environ.get("CONTROLLER_URL", "https://10.10.0.1")
username = os.environ.get("CONTROLLER_USERNAME", "apiaccess")
password = os.environ.get("CONTROLLER_PASSWORD")
site_id = os.environ.get("SITE_ID", "default")

# Google Sheets Configuration
google_sheets_creds = os.environ.get("SERVICE_ACCOUNT_JSON", "service-account.json")
sheet_name = os.environ.get("SHEET_NAME", "Home IP Space")

# Authenticate with Google Sheets
scope = [
    "https://spreadsheets.google.com/feeds",
    "https://www.googleapis.com/auth/drive",
]
creds = ServiceAccountCredentials.from_json_keyfile_name(google_sheets_creds, scope)
client = gspread.authorize(creds)

# Fetch the Google Sheet
sheet = client.open(sheet_name)

# Authenticate with the controller
session = requests.Session()
login_payload = {"username": username, "password": password}

response = session.post(
    f"{controller_url}/api/auth/login", json=login_payload, verify=False
)
if response.status_code == 200:
    print("Authenticated successfully.")
else:
    print(f"Authentication failed: {response.status_code} - {response.text}")
    exit()

# Capture CSRF Token if available
headers = {}
if response.headers.get("X-CSRF-Token"):
    headers["X-CSRF-Token"] = response.headers["X-CSRF-Token"]

# Check if a client with the given MAC address exists
response = session.get(
    f"{controller_url}/proxy/network/api/s/{site_id}/rest/user",
    verify=False,
    headers=headers,
)

if response.status_code == 200:
    clients = response.json().get("data", [])
else:
    print(f"Failed to fetch clients: {response.status_code} - {response.text}")
    exit()

# Process each sheet in the Google Sheet
sheets_to_process = ["10.10.0.0/24", "10.10.2.0/24", "10.10.5.0/24", "10.10.6.0/24"]

for sheet_title in sheets_to_process:
    worksheet = sheet.worksheet(sheet_title)
    rows = worksheet.get_all_records()  # Returns data as a list of dictionaries

    for row in rows:
        mac_address = row.get("Host")
        static_ip = row.get("IP")
        name = row.get("Name")
        roles = row.get("Notes")

        # Skip rows without a MAC address
        if not mac_address:
            print(f"Skipping {name} - No MAC address provided.")
            continue

        # Normalize MAC address
        mac_address = mac_address.lower()

        # Check if the MAC address already exists
        client = next((c for c in clients if c["mac"] == mac_address), None)

        reservation_payload = {
            "name": name,
            "note": roles,
            "mac": mac_address,
            "fixed_ip": static_ip,
            "use_fixedip": True,
        }
        if client:
            # Update existing reservation
            client_id = client["_id"]
            response = session.put(
                f"{controller_url}/proxy/network/api/s/{site_id}/rest/user/{client_id}",
                json=reservation_payload,
                verify=False,
                headers=headers,
            )
            if response.status_code == 200:
                print(
                    f"Static IP reservation updated successfully for {name} ({mac_address})."
                )
            else:
                print(
                    f"Failed to update static IP for {name}: {response.status_code} - {response.text}"
                )
        else:
            # Create new reservation
            response = session.post(
                f"{controller_url}/proxy/network/api/s/{site_id}/rest/user",
                json=reservation_payload,
                verify=False,
                headers=headers,
            )
            if response.status_code == 200:
                print(
                    f"Static IP reservation created successfully for {name} ({mac_address})."
                )
            else:
                print(
                    f"Failed to reserve static IP for {name}: {response.status_code} - {response.text}"
                )
