# Vertical Pod Autoscaler (VPA)

Static manifests vendored from [kubernetes/autoscaler](https://github.com/kubernetes/autoscaler) at git tag **`vertical-pod-autoscaler-1.6.0`** (VPA container images `registry.k8s.io/autoscaling/*:1.6.0`).

## Regenerating `vpa-generated.yaml`

On a machine with `bash` and `kubectl`:

```bash
WORKDIR=$(mktemp -d)
git clone --depth 1 --branch vertical-pod-autoscaler-1.6.0 https://github.com/kubernetes/autoscaler.git "$WORKDIR/autoscaler"
cd "$WORKDIR/autoscaler/vertical-pod-autoscaler"
REGISTRY=registry.k8s.io/autoscaling TAG=1.6.0 ./hack/vpa-process-yamls.sh print > vpa-print.yaml
```

Copy `vpa-print.yaml` to this directory as `vpa-generated.yaml`. Do **not** commit the TLS Secret into that file; TLS is GitOps-managed via `sealed-vpa-tls-certs.yaml`.

## TLS (`vpa-tls-certs`)

The admission webhook expects Secret `vpa-tls-certs` in `kube-system` with keys `caKey.pem`, `caCert.pem`, `serverKey.pem`, and `serverCert.pem`. The `print` output does not include this Secret.

Regenerate long-lived material with `openssl` (same logical flow as upstream `gencerts.sh`), then seal for this cluster:

```bash
# After producing /tmp/vpa-tls-secret.yaml (kubectl create secret generic ... --dry-run=client -o yaml)
kubeseal --format yaml -f /tmp/vpa-tls-secret.yaml -w sealed-vpa-tls-certs.yaml
```

Certs are issued for ~100000 days in the scripted flow; rotation and policy are handled out of band.

## Verification

```bash
kubectl get crd verticalpodautoscalers.autoscaling.k8s.io
kubectl -n kube-system get pods -l app=vpa-admission-controller
kubectl -n kube-system get pods -l app=vpa-recommender
kubectl -n kube-system get pods -l app=vpa-updater
```

All controller pods should be `Running` and the CRD should exist.

## Why `kube-system`

VPA components are namespaced to `kube-system` in the upstream render; this matches the default layout for cluster add-ons on this cluster.
