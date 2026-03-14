#!/usr/bin/env python3
"""Seedbox media syncer: loop that checks ISP and rsyncs when on WAN1."""
import datetime
import logging
import os
import signal
import subprocess
import time

import requests

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
log = logging.getLogger(__name__)

REQUIRED_ENV = (
    "REMOTE_USER", "REMOTE_HOST", "REMOTE_DIR", "LOCAL_DIR",
    "UDM_IP", "UDM_USERNAME", "UDM_PASSWORD",
)

def get_config():
    """Load config from env; raise ValueError if required vars missing."""
    missing = [k for k in REQUIRED_ENV if not os.environ.get(k)]
    if missing:
        raise ValueError(f"Missing required env: {missing}")
    return {
        "remote_user": os.environ["REMOTE_USER"],
        "remote_host": os.environ["REMOTE_HOST"],
        "remote_dir": os.environ["REMOTE_DIR"].rstrip("/"),
        "local_dir": os.environ["LOCAL_DIR"].rstrip("/"),
        "udm_ip": os.environ["UDM_IP"],
        "udm_username": os.environ["UDM_USERNAME"],
        "udm_password": os.environ["UDM_PASSWORD"],
        "owner_user": os.environ.get("OWNER_USER", "root"),
        "owner_group": os.environ.get("OWNER_GROUP", "root"),
        "day_bwlimit": os.environ.get("DAY_BWLIMIT", "30m"),
        "night_bwlimit": os.environ.get("NIGHT_BWLIMIT", "50m"),
        "ssh_key_path": os.environ.get("SSH_KEY_PATH", os.path.expanduser("~/.ssh/id_rsa")),
        "sleep_interval": int(os.environ.get("SLEEP_INTERVAL", "10")),
        "isp_down_sleep_interval": int(os.environ.get("ISP_DOWN_SLEEP_INTERVAL", "60")),
        "avail_threshold": float(os.environ.get("AVAIL_THRESHOLD", "1.0")),
        "debug": os.environ.get("DEBUG", "").lower() in ("1", "true", "yes"),
    }

def _availability(obj):
    if not obj:
        return 0.0
    if "availability" in obj and obj["availability"] is not None:
        return float(obj["availability"])
    vals = []
    for m in obj.get("alerting_monitors") or []:
        if m.get("availability") is not None:
            vals.append(float(m["availability"]))
    for m in obj.get("monitors") or []:
        if m.get("availability") is not None:
            vals.append(float(m["availability"]))
    return max(vals) if vals else 0.0

def parse_wan_status(health_data_list, threshold):
    """Given .data from health API, return 'WAN1' | 'WAN2' | 'Offline'."""
    for item in health_data_list or []:
        if (item.get("subsystem") or "").lower() != "wan":
            continue
        stats = item.get("uptime_stats") or {}
        wan1 = _availability(stats.get("WAN"))
        wan2 = _availability(stats.get("WAN2"))
        if wan2 > threshold and wan1 <= threshold:
            return "WAN2"
        if wan1 > threshold:
            return "WAN1"
        return "Offline"
    return "Offline"

def _normalize_health_data(data):
    """Convert API health payload to list of items with subsystem + uptime_stats.
    UniFi may return .data as array or as dict keyed by subsystem name.
    """
    raw = data if data is not None else []
    if isinstance(raw, dict):
        # e.g. {"wan": {"uptime_stats": {...}}, "wlan": {...}}
        out = []
        for name, obj in raw.items():
            if isinstance(obj, dict):
                item = dict(obj)
                item.setdefault("subsystem", name)
                out.append(item)
        return out
    if isinstance(raw, list):
        return raw
    return []


def get_isp_status(config):
    """Call UDM API; return 'WAN1' | 'WAN2' | 'Offline'."""
    base = f"https://{config['udm_ip']}"
    session = requests.Session()
    session.verify = False
    debug = config.get("debug")
    try:
        r = session.post(
            f"{base}/api/auth/login",
            json={"username": config["udm_username"], "password": config["udm_password"]},
            timeout=3,
        )
        if debug:
            log.debug("UDM login status=%s", r.status_code)
        if r.status_code != 200:
            if debug:
                log.debug("UDM login failed: %s %s", r.status_code, r.text[:200])
            return "Offline"
        # UniFi OS may set cookies with Path=/api so they are not sent to /proxy/network/...
        # Re-set cookies with path=/ so the health request receives them.
        host = config["udm_ip"]
        for c in session.cookies:
            session.cookies.set(c.name, c.value, path="/", domain=host)
        r = session.get(f"{base}/proxy/network/api/s/default/stat/health", timeout=3)
        if debug:
            log.debug("UDM health status=%s", r.status_code)
        if r.status_code != 200:
            if debug:
                log.debug("UDM health failed: %s %s", r.status_code, r.text[:200])
            return "Offline"
        body = r.json()
        data = body.get("data")
        health_list = _normalize_health_data(data)
        if debug:
            log.debug("health data type=%s items=%s", type(data).__name__, len(health_list))
        return parse_wan_status(health_list, config["avail_threshold"])
    except Exception as e:
        if debug:
            log.debug("get_isp_status error: %s", e, exc_info=True)
        return "Offline"

def ssh_socket_path(config):
    return f"/tmp/ssh_mux_{config['remote_host']}_22_{config['remote_user']}"

def start_ssh_master(config):
    sock = ssh_socket_path(config)
    key = config.get("ssh_key_path")
    cmd = ["ssh", "-M", "-S", sock, "-f", "-n", "-N", f"{config['remote_user']}@{config['remote_host']}"]
    if key:
        cmd[1:1] = ["-i", key]
    subprocess.run(cmd, check=True)

def run_ssh(config, socket_path, remote_cmd):
    key = config.get("ssh_key_path")
    cmd = ["ssh", "-S", socket_path, "-o", "BatchMode=yes", f"{config['remote_user']}@{config['remote_host']}", remote_cmd]
    if key:
        i = cmd.index("-S") + 2
        cmd[i:i] = ["-i", key]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0, result.stdout, result.stderr

def has_remote_files(config, socket_path):
    ok, out, _ = run_ssh(config, socket_path, f"ls -A {config['remote_dir']}")
    return ok and bool(out and out.strip())

def bwlimit_for_hour(config):
    h = datetime.datetime.now().hour
    return config["night_bwlimit"] if 0 <= h < 6 else config["day_bwlimit"]

def run_sync(config, socket_path):
    key = config.get("ssh_key_path", "")
    rsync_cmd = [
        "rsync", "-aPvz", "--progress", "--remove-source-files",
        "--bwlimit", bwlimit_for_hour(config),
        "-e", f"ssh -S {socket_path}" + (f" -i {key}" if key else ""),
        f"{config['remote_user']}@{config['remote_host']}:{config['remote_dir']}/",
        f"{config['local_dir']}/",
    ]
    subprocess.run(rsync_cmd, check=True)
    run_ssh(config, socket_path, f"find {config['remote_dir']} -type d -empty -delete")
    run_ssh(config, socket_path, f"mkdir -p {config['remote_dir']}")
    subprocess.run(["chown", "-R", f"{config['owner_user']}:{config['owner_group']}", config["local_dir"]], check=True)

def main():
    shutdown = [False]

    def on_sigterm(*_):
        shutdown[0] = True

    signal.signal(signal.SIGTERM, on_sigterm)
    config = get_config()
    if config.get("debug"):
        logging.getLogger().setLevel(logging.DEBUG)
    sock = ssh_socket_path(config)
    log.info("Starting SSH master")
    start_ssh_master(config)
    while not shutdown[0]:
        isp = get_isp_status(config)
        log.debug("ISP: %s", isp)
        if isp in ("Offline", "WAN2"):
            log.info("ISP %s, sleeping %s s", isp, config["isp_down_sleep_interval"])
            time.sleep(config["isp_down_sleep_interval"])
            continue
        if not has_remote_files(config, sock):
            time.sleep(config["sleep_interval"])
            continue
        log.info("Syncing (bwlimit=%s)", bwlimit_for_hour(config))
        try:
            run_sync(config, sock)
            log.info("Sync complete")
        except subprocess.CalledProcessError as e:
            log.warning("Sync failed: %s", e)
        time.sleep(config["sleep_interval"])
    log.info("Shutting down")

if __name__ == "__main__":
    if os.environ.get("ISP_DEBUG_RAW"):
        # One-shot: print raw API response for debugging (run with required env vars set).
        config = get_config()
        base = f"https://{config['udm_ip']}"
        session = requests.Session()
        session.verify = False
        print("=== Login ===")
        r = session.post(
            f"{base}/api/auth/login",
            json={"username": config["udm_username"], "password": config["udm_password"]},
            timeout=10,
        )
        print("Status:", r.status_code)
        print("=== Health ===")
        r2 = session.get(f"{base}/proxy/network/api/s/default/stat/health", timeout=10)
        print("Status:", r2.status_code)
        try:
            data = r2.json()
            print("Keys:", list(data.keys()) if isinstance(data, dict) else type(data))
            inner = data.get("data")
            print("data type:", type(inner).__name__)
            if isinstance(inner, dict):
                print("data keys:", list(inner.keys()))
            print("data (repr, first 2000 chars):", repr(inner)[:2000])
            print("=== Parsed ===")
            health_list = _normalize_health_data(inner)
            print("normalized items:", len(health_list))
            result = parse_wan_status(health_list, config["avail_threshold"])
            print("ISP result:", result)
        except Exception as e:
            print("Error:", e)
            print("Body:", r2.text[:500])
        raise SystemExit(0)
    main()
