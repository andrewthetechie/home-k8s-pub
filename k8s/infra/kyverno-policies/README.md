# Kyverno policies (Goldilocks namespace label)

Cluster-scoped **Kyverno** policies that must be applied **after** the Kyverno Helm chart in `../kyverno/` has installed CRDs and controllers.

## Why a separate directory

`kubectl apply` (even server-side) can fail on `ClusterPolicy` in the **same** manifest stream as CRDs: the `clusterpolicies.kyverno.io` CRD may not yet be **Established** when the API server resolves kinds, which produces `no matches for kind "ClusterPolicy"… ensure CRDs are installed first`. Splitting policies into this app avoids that race.

The infra ApplicationSet assigns **`argocd.argoproj.io/sync-wave: "1"`** to this Application only (see `nauvoo-v2/manifests/argocd/appset-infra.yaml`) so it syncs after wave-`0` apps, including **`kyverno`**.

## Contents

- **`goldilocks-default-namespace-label`** — sets `goldilocks.fairwinds.com/enabled=true` on non-`kube-*` namespaces unless `goldilocks.fairwinds.com/enabled=false`.

## Manual apply

After `../kyverno/` is applied and CRDs are Established:

```bash
kubectl kustomize nauvoo-v2/manifests/infra/kyverno-policies \
  | kubectl apply --server-side --force-conflicts --field-manager=kustomize -f -
```
