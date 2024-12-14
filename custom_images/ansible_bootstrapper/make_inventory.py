import yaml
import os

HOST = os.environ.get("NAME")
IP = os.environ.get("IP")
ROLES = os.environ.get("ROLES").split(",")

with open(f"/hosts/{HOST}/inventory/inventory.yaml", "r") as fh:
    host_inventory = yaml.safe_load(fh)

host_inventory["all"]["hosts"][HOST]["ansible_host"] = IP
host_inventory["all"]["hosts"][HOST]["ansible_ssh_private_key_file"] = (
    "/secret/ansible-key"
)
host_inventory["all"]["hosts"][HOST]["ansible_ssh_extra_args"] = (
    "-o StrictHostKeyChecking=no"
)

host_inventory["all"]["hosts"][HOST]["roles"] = ROLES


with open(f"/hosts/{HOST}/inventory/inventory.yaml", "w") as fh:
    yaml.safe_dump(host_inventory, fh)
