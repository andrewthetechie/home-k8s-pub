# Kyverno

Helm chart **[kyverno](https://github.com/kyverno/kyverno)** — policy engine for cluster policies.

- **Chart version:** `3.3.9` (`https://kyverno.github.io/kyverno/`) — Kyverno app **`v1.13.6`**, appropriate for **Kubernetes 1.28** (see [Kyverno compatibility](https://kyverno.io/docs/installation/#compatibility-matrix); upgrade the chart when the cluster upgrades).
- **Namespace:** `kyverno`

**Policies** (e.g. default Goldilocks namespace labels) live in the sibling app **`../kyverno-policies/`** so `ClusterPolicy` is applied **after** Kyverno CRDs are **Established** (see below).

## `values.yaml` notes

- **Hooks that pull `kubectl`:** The chart defaults to **`docker.io/bitnami/kubectl`**. Many mirrors cannot pull it reliably. This overlay disables **`policyReportsCleanup`**, **`webhooksCleanup`**, sets **`config.preserve: false`**, and **`crds.migration.enabled: false`** so installs do not create Jobs that need a separate kubectl image. Re-enable any of these when [upgrading](https://github.com/kyverno/kyverno/releases) or if you need Helm’s uninstall/cleanup behavior and your registry can reach those images.
- **Helm test Pods:** Kustomize **`patches/delete-pod-*.yaml`** remove the chart’s `helm.sh/hook: test` Pods. Busybox `wget` to HTTPS health endpoints can hang indefinitely here; those smoke tests are optional for GitOps. Run **`helm test kyverno -n kyverno`** from a machine with working chart defaults if you want them.

## Bootstrap existing namespaces

Admission policies apply to **new** requests and **updates**. Namespaces that **already exist** and are never updated do not receive the label until something changes the object. After Kyverno and the policy are synced, run a **one-time** label pass (optional) for existing namespaces:

```bash
kubectl get ns -o json | jq -r '
  .items[]
  | select(.metadata.name | startswith("kube-") | not)
  | select((.metadata.labels["goldilocks.fairwinds.com/enabled"] // "") != "false")
  | .metadata.name
' | xargs -n1 -I{} kubectl label ns {} goldilocks.fairwinds.com/enabled=true --overwrite
```

GNU `xargs` supports `-r` (skip if empty); macOS `xargs` does not — if you see errors on empty input, wrap the pipeline so it only runs when `jq` emits lines.

## Argo CD and `kubectl apply`

**Large Kyverno CRDs:** Client-side `kubectl apply` stores the full manifest in `kubectl.kubernetes.io/last-applied-configuration`, which can exceed the API server limit (**262144 bytes**) for Kyverno’s CRDs. The infra ApplicationSet enables **`ServerSideApply=true`**. If Argo still errors on CRDs, the Kyverno chart [recommends](https://github.com/kyverno/kyverno/tree/main/charts/kyverno#notes-on-using-argocd) adding **`Replace=true`** to **this Application’s** sync options only.

**Do not** set a top-level `namespace:` field in this directory’s `kustomization.yaml`: Kustomize would add `metadata.namespace` to every object, including cluster-scoped kinds (CRDs). Helm namespaced resources stay in `kyverno` via `helmCharts[].namespace` only.

## Applying manually (without Argo)

Use **server-side apply**. If these objects were ever managed with **client-side** `kubectl apply`, add **`--force-conflicts`** so SSA can take over fields owned by `kubectl-client-side-apply`.

**1. Install Kyverno (Helm chart + namespace only):**

```bash
kubectl kustomize --enable-helm nauvoo-v2/manifests/infra/kyverno \
  | kubectl apply --server-side --force-conflicts --field-manager=kustomize -f -
```

**2. Wait until the ClusterPolicy CRD is Established** (otherwise `kubectl` cannot map `ClusterPolicy` in the same apply pass):

```bash
kubectl wait --for=condition=Established crd/clusterpolicies.kyverno.io --timeout=120s
```

**3. Apply policies** (sibling directory):

```bash
kubectl kustomize nauvoo-v2/manifests/infra/kyverno-policies \
  | kubectl apply --server-side --force-conflicts --field-manager=kustomize -f -
```

## Verification

- `kubectl -n kyverno get deploy,pods`
- `kubectl get clusterpolicy goldilocks-default-namespace-label` (after `kyverno-policies` is applied)
- Create a test namespace not starting with `kube-` → confirm label `goldilocks.fairwinds.com/enabled=true`
- Label a test namespace `goldilocks.fairwinds.com/enabled=false` → confirm it stays `false`
