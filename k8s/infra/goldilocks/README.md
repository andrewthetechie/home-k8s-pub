# Goldilocks

Helm chart **[goldilocks](https://github.com/FairwindsOps/goldilocks)** from Fairwinds:

- **Chart version:** `10.3.0` (`https://charts.fairwinds.com/stable`)

> **Why `vpa.enabled` and `metrics-server.enabled` are false:** VPA controllers and CRDs are installed by the separate `vertical-pod-autoscaler` app, and this cluster already runs `nauvoo-v2/manifests/infra/metrics-server`; enabling either in the chart would duplicate workloads or conflict with GitOps ownership.

## Access

Dashboard (ClusterIP) — after sync:

```bash
kubectl -n goldilocks port-forward svc/goldilocks-dashboard 8080:80
```

Then open `http://localhost:8080`.

## Dependencies

Goldilocks needs **VPA** (recommender and CRDs) healthy before recommendations appear in the UI. Sync order: deploy VPA first, then Goldilocks.

Ingress is omitted here; add later with the cluster `nginx` ingress and cert-manager if you want external access.

## Enabling namespaces

Label namespaces you want reconciled:

```bash
kubectl label ns <your-namespace> goldilocks.fairwinds.com/enabled=true --overwrite
```

After metrics and VPA have collected data, check the dashboard for rightsizing suggestions.
