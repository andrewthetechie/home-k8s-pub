#!/bin/bash

set -e
python /make_inventory.py

cd /hosts/$NAME

make install

pwd
SECRET_FILE_PATH=/secrets/ansible-vault-password make run-all