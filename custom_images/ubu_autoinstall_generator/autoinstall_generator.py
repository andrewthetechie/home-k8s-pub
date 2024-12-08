import gspread
from oauth2client.service_account import ServiceAccountCredentials
import os
import yaml
from pathlib import Path
import json
from minio import Minio
from io import BytesIO


BOOTSTRAP_URL = os.environ.get("BOOTSTRAP_URL", "")
TEMPLATE_DIR = Path(os.environ.get("TEMPLATE_DIR", "./"))
APT_CACHE_URL = os.environ.get(
    "APT_CACHE_URL", "http://apt.cache.herrington.services:3142"
)

MINIO_HOST = os.environ.get("MINIO_URL", "chrisjen.herrington.services:9000")
BUCKET = os.environ.get("BUCKET")
ACCESS_KEY = os.environ.get("ACCESS_KEY")
SECRET_KEY = os.environ.get("SECRET_KEY")


def get_set_default(object, key, default):
    value = object.get(key, default)
    object[key] = value


def generate_autoinstall(
    name: str, roles: list[str], ip: str, mac_address: str
) -> tuple[dict, dict, dict]:
    global BOOTSTRAP_URL
    global TEMPLATE_DIR

    template_file = TEMPLATE_DIR / f"{name}.yaml"
    if not template_file.exists:
        raise Exception(f"{template_file} does not exist")
    try:
        with open(template_file, "r") as fh:
            template_data = yaml.safe_load(fh)
    except:
        print(f"Unable to load {template_file}. Using defaults")
        template_data = {}
        template_data["autoinstall"] = {}
    template_data["version"] = 1
    get_set_default(template_data["autoinstall"], "proxy", APT_CACHE_URL)
    get_set_default(
        template_data["autoinstall"], "kernel", {"package": "linux-generic"}
    )
    get_set_default(
        template_data["autoinstall"],
        "keyboard",
        {
            "layout": "us",
            "toggle": None,
            "variant": "",
        },
    )

    template_data["autoinstall"]["version"] = 1
    get_set_default(template_data["autoinstall"], "refresh-installer", {"update": True})
    get_set_default(template_data["autoinstall"], "codecs", {"install": False})
    get_set_default(template_data["autoinstall"], "drivers", {"install": False})
    get_set_default(template_data["autoinstall"], "oem", {"install": True})
    get_set_default(
        template_data["autoinstall"],
        "source",
        {"id": "ubuntu-server", "search_drivers": False},
    )
    get_set_default(template_data["autoinstall"], "updates", "security")
    get_set_default(
        template_data["autoinstall"],
        "apt",
        {"preserve_sources_list": False, "geoip": True, "fallback": "offline-install"},
    )

    packages = template_data["autoinstall"].get("packages", [])
    if "curl" not in packages:
        packages.append("curl")
    template_data["autoinstall"]["packages"] = packages

    if "shutdown" not in template_data["autoinstall"].keys():
        template_data["autoinstall"]["shutdown"] = "reboot"

    if "timezone" not in template_data["autoinstall"].keys():
        template_data["autoinstall"]["timezone"] = "America/Chicago"

    if "locale" not in template_data["autoinstall"].keys():
        template_data["autoinstall"]["locale"] = "en_US"

    if "ssh" not in template_data["autoinstall"].keys():
        template_data["autoinstall"]["ssh"] = {
            "install-server": True,
            "allow-pw": False,
        }

    if "update" not in template_data["autoinstall"].keys():
        template_data["autoinstall"]["update"] = "all"

    user_data = template_data["autoinstall"].get("user-data", {})
    if "hostname" not in user_data.keys():
        user_data["hostname"] = name
    users = user_data.get(
        "users",
        [],
    )
    users.append(
        {
            "name": "andrew",
            "sudo": "ALL=(ALL) NOPASSWD:ALL",
            "ssh_authorized_keys": [
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHQP0IzdUHOZJF7cwfygJ/EM7jvWfhGJgeLBf24xsdln aherrington@eunice"
            ],
            "lock_passwd": False,
        }
    )
    users.append(
        {
            "name": "ansible",
            "sudo": "ALL=(ALL) NOPASSWD:ALL",
            "ssh_authorized_keys": [
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9rJ03do1bx9efSglD9V8vhWgGd3S5SWXzjR1nB8INU deploy-key"
            ],
            "lock_passwd": False,
        }
    )
    user_data["users"] = users
    run_cmds = user_data.get("runcmd", [])

    onboard_data = json.dumps(
        {"name": name, "roles": roles, "mac": mac_address, "ip": ip}
    )
    run_cmds.append(
        [
            "curl",
            "-X",
            "POST",
            BOOTSTRAP_URL,
            "-H",
            "Content-Type: application/json",
            "-d",
            f"{onboard_data}",
        ]
    )
    user_data["runcmd"] = run_cmds
    template_data["autoinstall"]["user-data"] = user_data

    meta_data = {"instance_id": name, "roles": roles}
    return template_data, meta_data, {}


if __name__ == "__main__":
    # Google Sheets Configuration
    google_sheets_creds = os.environ.get("SERVICE_ACCOUNT_JSON", "service-account.json")
    sheet_name = os.environ.get("SHEET_NAME", "Home IP Space")
    worksheet_name = os.environ.get("WORKSHEET_NAME", "10.10.0.0/24")

    # Authenticate with Google Sheets
    scope = [
        "https://spreadsheets.google.com/feeds",
        "https://www.googleapis.com/auth/drive",
    ]
    creds = ServiceAccountCredentials.from_json_keyfile_name(google_sheets_creds, scope)
    client = gspread.authorize(creds)

    # Fetch the Google Sheet
    sheet = client.open(sheet_name)

    worksheet = sheet.worksheet(worksheet_name)
    rows = worksheet.get_all_records()

    minio = Minio(MINIO_HOST, access_key=ACCESS_KEY, secret_key=SECRET_KEY)

    for row in rows:
        ip = row.get("IP")
        mac_address = row.get("Host")
        name = row.get("Name")
        roles = row.get("Roles")

        # Skip rows without a MAC address
        if not mac_address:
            # print(f"Skipping {name} - No MAC address provided.")
            continue

        if not roles:
            # print(f"Skipping {name} - No Roles provided.")
            continue

        roles_split = roles.lower().split(",")

        if "ubuntu" not in roles_split:
            print(f"Skipping {name} - Not Ubuntu role.")
            continue

        try:
            user_data, meta_data, vendor_data = generate_autoinstall(
                name, roles_split, ip, mac_address
            )
        except Exception as exc:
            print(exc)
            continue
        mac_hyphenated = mac_address.replace(":", "-").lower()

        # Write to MinIO
        try:
            # Write user_data
            user_data_content = f"#cloud-config\n{yaml.dump(user_data)}"
            minio.put_object(
                BUCKET,
                f"cloud-init/{mac_hyphenated}/user-data",
                BytesIO(user_data_content.encode("utf-8")),
                length=len(user_data_content),
                content_type="text/x-yaml",
            )

            # Write meta_data
            meta_data_content = yaml.dump(meta_data)
            minio.put_object(
                BUCKET,
                f"cloud-init/{mac_hyphenated}/meta-data",
                BytesIO(meta_data_content.encode("utf-8")),
                length=len(meta_data_content),
                content_type="text/x-yaml",
            )

            # Write vendor_data
            vendor_data_content = yaml.dump(vendor_data)
            minio.put_object(
                BUCKET,
                f"cloud-init/{mac_hyphenated}/vendor-data",
                BytesIO(vendor_data_content.encode("utf-8")),
                length=len(vendor_data_content),
                content_type="text/x-yaml",
            )

            print(f"Successfully wrote cloud-init data for {name} to MinIO.")
        except Exception as e:
            print(f"Failed to write cloud-init data for {name}: {e}")
