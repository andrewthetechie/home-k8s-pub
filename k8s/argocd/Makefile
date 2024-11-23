.DEFAULT_GOAL := help

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-40s\033[0m %s\n", $$1, $$2}'

create-ssh-secret: ## creates secret.json with the ArgoCD secret. Key must be in ~/.ssh/argo_ed25519
	kubectl -n argocd create secret generic private-repo --from-literal=type=git --from-literal=url=git@github.com:andrewthetechie/home-k8s.git --from-file=sshPrivateKey=/Users/andrew/.ssh/argo_ed25519 -o json --dry-run=client | jq '.metadata.labels |= {"argocd.argoproj.io/secret-type": "repo-creds"}' > secret.json

seal-secret: create-ssh-secret ## creates a kubeseal secret from secret.json, check this into git
	kubeseal -o yaml < secret.json > sealed-secret-repo.yaml