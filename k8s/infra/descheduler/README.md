# Descheduler

Helm chart **[descheduler](https://github.com/kubernetes-sigs/descheduler)** from the official repo:

- **Chart version:** `0.35.0`
- **Repo:** `https://kubernetes-sigs.github.io/descheduler/`

The release runs in `kube-system` on a conservative CronJob schedule (`*/15 * * * *`) to limit eviction churn in the homelab. Bump the chart version when upgrading; check upstream release notes for breaking changes to policies or values.
