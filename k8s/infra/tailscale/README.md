<https://tailscale.com/kb/1185/kubernetes/>

Setup a tailscale router following the direcitons

# Get service ip cidr range

SVCRANGE=$(echo '{"apiVersion":"v1","kind":"Service","metadata":{"name":"tst"},"spec":{"clusterIP":"1.1.1.1","ports":[{"port":443}]}}' | kubectl apply -f - 2>&1 | sed 's/.*valid IPs is //')
echo $SVCRANGE

# Setup namespace and secret

Apply namespace

Get an Auth Key <https://tailscale.com/kb/1085/auth-keys/>
-- Keys expire in 90 days, so you'll need a new key
echo -n KEY | kubectl -n tailscale create secret generic tailscale-subnet-router-secrets --dry-run=client --from-file=AUTH_KEY=/dev/stdin -o yaml | kubeseal > sealed-secret.yaml
Apply sealed secret

# helm install

helm repo add gtaylor <https://gtaylor.github.io/helm-charts>
helm install \
  subnet-router \
  gtaylor/tailscale-subnet-router \
  -n tailscale --values values.yaml
  