# UPGRADE PLAN — tvapp-m3u

**Cluster constraint:** Kubernetes **v1.28.1** (cannot be upgraded). All target versions below are verified compatible with Kubernetes 1.28.

## Current versions

| Component | Version |
| --- | --- |
| Helm chart | `app-template` (bjw-s-labs) **4.6.2** |
| Application image | `ghcr.io/thebinaryninja/tvapp2` **1.5.5** |

- Chart pinned in `kustomization.yaml` → `helmCharts[0].version`
- Image pinned in `values.yaml` → `controllers.tvappm3u.containers.app.image.tag`

## Target versions (newest compatible with K8s 1.28)

| Component | Target | Why |
| --- | --- | --- |
| Helm chart | `app-template` **5.1.0** | Latest chart (2026-08-16). Its `Chart.yaml` declares `kubeVersion: '>=1.28.0-0'`, so it is explicitly supported on our K8s 1.28. Requires a 4.x→5.x migration (below) that is low-risk for this app's minimal values. |
| Application image | `ghcr.io/thebinaryninja/tvapp2` **1.5.9** | Latest published TvApp2 release; its digest matches the `latest` tag (i.e. 1.5.9 is what `latest` points to). 1.5.5 → 1.5.9 are all 1.5.x patch/minor releases — pure image bump, no config change. |

## Newest overall & why it is / is not the target

- **app-template chart:** 5.1.0 **is** the newest and **is adopted** (K8s 1.28-compatible).
- **TvApp2 image:** 1.5.9 is the newest **and the final** release. ⚠️ The upstream project is **deprecated / archived / unmaintained** — see notes below. No newer TvApp2 build exists, so there is nothing further to upgrade to within this application. No version is being skipped.

## Breaking changes / migration notes

### Chart 4.x → 5.x (app-template 5.1.0)
Per the official [Upgrading from v4.x to v5.x](https://bjw-s-labs.github.io/helm-charts/docs/app-template/upgrades/4-to-5/) guide:

1. **`rawResources` restructure** — raw manifests now go under a `manifest` key, labels/annotations move under `metadata`, and the `spec` key is removed. **Not applicable**: this app defines no `rawResources`.
2. **Default ServiceAccount** — a dedicated *unprivileged* ServiceAccount named after the Helm release is now created by default (previously pods used the namespace default SA). TvApp2 needs no special permissions, so this is harmless; if undesired you can opt out with `global.createDefaultServiceAccount: false`.
3. **ServiceMonitor / PodMonitor `jobLabel` default** changed — **not applicable**: none configured.
4. **NetworkPolicy controller restructure** — **not applicable**: none configured.

Because this app's `values.yaml` only sets `controllers.<name>.containers.app.image`, `service`, and `ingress`, the 4.x→5.x migration is **low-risk**. The only behavioral change is the new default ServiceAccount.

### Image 1.5.5 → 1.5.9
Patch releases within the 1.5.x series. No env-var, config, persistence, or ingress changes required. The app listens on TCP **4124** and is exposed via nginx ingress as configured — unchanged.

## Step-by-step upgrade plan

1. **Bump chart** in `kustomization.yaml`: change `version: 4.6.2` → `version: 5.1.0` under `helmCharts[0]`.
2. **Bump image** in `values.yaml`: change `tag: 1.5.5` → `tag: 1.5.9` under `controllers.tvappm3u.containers.app.image`.
3. *(Optional cleanup)* The `charts/` directory contains a **stale** vendored `app-template` at `Chart.yaml` version **3.3.2**. Kustomize's `helmChartInflationGenerator` pulls from the remote repo (4.6.2→5.1.0) and ignores this vendored copy, but it is confusing. Remove `charts/` (not required for the upgrade to function).
4. **Commit** both files and push. The app is managed by the ArgoCD application set (apps/ layer), so it reconciles automatically.
5. **Verify rollout** (see verification below).

## Rollback plan

- Revert both pins: `kustomization.yaml` back to `4.6.2` and `values.yaml` back to `1.5.5`, commit + push. ArgoCD will roll back the release.
- If the new **default ServiceAccount** causes RBAC issues (unexpected in this app), either restore the previous config or add `global.createDefaultServiceAccount: false`.

## Post-upgrade verification

- `kubectl rollout status deploy/tvapp-m3u -n piracy` — expect `successfully rolled out`.
- `kubectl get deploy tvapp-m3u -n piracy -o jsonpath='{.spec.template.spec.containers[0].image}'` → `ghcr.io/thebinaryninja/tvapp2:1.5.9`.
- Pod `Running`/`Ready`; new unprivileged ServiceAccount `tvapp-m3u` created (expected v5 behavior).
- Service + nginx ingress healthy; verify the M3U playlist and EPG endpoints respond for the configured channels.
- Confirm homepage/uptime checks for the app are green.

## Observations / risks (no action required for this upgrade)

- **⚠️ Project EOL:** TvApp2 is archived/deprecated. The author's successor is **masqueradarr** (`TheBinaryNinja/masqueradarr`), currently in beta with the container **not yet published** to a registry (GHCR anonymous pull returned nothing). Recommendation: stay on TvApp2 `1.5.9` now, and track masqueradarr for a deliberate migration *later* — that is a product/replacement decision, out of scope for this routine upgrade.
- **Pre-existing namespace quirk:** `namespace.yaml` creates the `piracy` namespace and `kustomization.yaml` has a global `namespace: piracy`; the helm release metadata says `tvapp-m3u`. As a result the app is actually deployed into the **`piracy`** namespace (`kubectl get deploy tvapp-m3u -n piracy` is where it lives); there is no `tvapp-m3u` namespace. This is a pre-existing inconsistency unrelated to the version upgrade and is left untouched here.
- **Pinning:** keep an explicit tag (`1.5.9`) rather than `latest` — already the pattern and retained.

## Summary

| Component | Current → Target |
| --- | --- |
| Chart | app-template 4.6.2 → **5.1.0** (K8s ≥1.28 supported; low-risk 4→5 migration) |
| Image | tvapp2 **1.5.5 → 1.5.9** (final release; project EOL) |
| Blockers | None for the version upgrade. TvApp2 is EOL — plan/monitor masqueradarr replacement at a later, deliberate decision point. |
