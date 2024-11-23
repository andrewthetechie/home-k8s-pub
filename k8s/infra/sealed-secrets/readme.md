https://artifacthub.io/packages/helm/bitnami-labs/sealed-secrets

helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install --namespace kube-system sealed-secrets --set-string fullnameOverride=sealed-secrets-controller sealed-secrets/sealed-secrets 

download and install kubeseal from https://github.com/bitnami-labs/sealed-seexitcrets/releases

kubeseal --fetch-cert \
--controller-namespace=kube-system \
> ~/.kube/sealed-pub-cert.pem

kubeseal --cert ~/.kube/sealed-pub-cert.pem --format yaml < secret.yaml > sealed-secret.yaml
