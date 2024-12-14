.DEFAULT_GOAL := help
SECRET_FILE_PATH ?= password

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-40s\033[0m %s\n", $$1, $$2}'

install: install-ansible install-roles ## installs ansible and roles

install-ansible:
	pip install -r requirements.txt

install-roles:   # install ansible roles
	ansible-galaxy install -r requirements.yaml

run-all: run-base run-jellyfin

run-base:  ## Run the base ansible playbook that sets up security and installs requirements
	ansible-playbook -i inventory/inventory.yaml -e @secrets.enc --vault-password-file $(SECRET_FILE_PATH) playbooks/base.yaml

run-jellyfin:
	ansible-playbook -i inventory/inventory.yaml -e @secrets.enc --vault-password-file $(SECRET_FILE_PATH) playbooks/jellyfin.yaml

run-backup:
	ansible-playbook -i inventory/inventory.yaml -e @secrets.enc --vault-password-file $(SECRET_FILE_PATH) -e "repo_path=jellyfin" playbooks/backup.yaml