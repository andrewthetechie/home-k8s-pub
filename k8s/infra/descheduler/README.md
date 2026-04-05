# Descheduler

Helm chart **[descheduler](https://github.com/kubernetes-sigs/descheduler)** from the official repo:

- **Chart version:** `0.35.0`
- **Repo:** `https://kubernetes-sigs.github.io/descheduler/`

The release runs in `kube-system` on a conservative CronJob schedule (`*/15 * * * *`) to limit eviction churn in the homelab. Bump the chart version when upgrading; check upstream release notes for breaking changes to policies or values.

**Policy note:** The chart’s default `DefaultEvictor` enables extra pod protection `PodsWithPVC`, which makes the binary watch `PersistentVolumeClaim` cluster-wide. The chart’s bundled `ClusterRole` does not grant `persistentvolumeclaims` list/watch, so logs show RBAC errors and the job may not complete. `values.yaml` sets `extraEnabled: []` for `DefaultEvictor` so RBAC matches the chart. To protect PVC-backed pods you would add PVC rules to RBAC (or a separate `ClusterRole`) and re-enable that protection.
