# Descheduler

Helm chart **[descheduler](https://github.com/kubernetes-sigs/descheduler)** from the official repo:

- **Chart version:** `0.30.2`
- **Repo:** `https://kubernetes-sigs.github.io/descheduler/`

The release runs in `kube-system` on a conservative CronJob schedule (`*/15 * * * *`) to limit eviction churn in the homelab. Bump the chart version when upgrading; check upstream release notes for breaking changes to policies or values.

**Policy note:** The chart’s `DefaultEvictor` uses `ignorePvcPods: true` to protect PVC-backed pods without needing a cluster-wide `PersistentVolumeClaim` list/watch, keeping RBAC aligned with the chart’s bundled `ClusterRole`. `evictLocalStoragePods: true` keeps local-storage pods evictable. Note: v0.30.2 is the highest descheduler release whose tested k8s range (1.28–1.30) includes this cluster’s Kubernetes v1.28.1; bumping beyond v0.30.x requires a control-plane upgrade.
