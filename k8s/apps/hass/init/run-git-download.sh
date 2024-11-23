#!/bin/sh
# Install requirements for the download script and execute it

SCRIPT_PATH="${SCRIPT_PATH:-/scripts}"

set -e
apt-get update && apt-get -y install git

pip install gitpython pyyaml httpx aiofiles
python "${SCRIPT_PATH}/git-download.py"
