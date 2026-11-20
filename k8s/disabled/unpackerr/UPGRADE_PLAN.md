# Unpackerr — Upgrade Plan

Cluster constraint: **Kubernetes v1.28.1 (CANNOT be upgraded).**
Any chart/image chosen must run on k8s 1.28.

## Current deployed versions

| Component | Version | Where pinned |
| --- | --- | --- |
| BJW-S `app-template` helm chart | `4.6.2` | `kustomization.yaml` (`helmCharts[].version`) |
| Application image `golift/unpackerr` | `0.15.2` | `values.yaml` → `controllers.unpackerr.containers.app.image.tag` |
| Kubernetes | `1.28.1` | cluster |

Deployment model: kustomize `helmChartInflationGenerator` inflates the `app-template`
chart from `https://bjw-s-labs.github.io/helm-charts`, with `values.yaml` providing the
app config (image, env, NFS persistence, service/ingress disabled).

## Recommended target (newest compatible with k8s 1.28)

| Component | Current | Target | Compatible with 1.28? |
| --- | --- | --- | --- |
| `app-template` chart | `4.6.2` | **`5.1.0`** | ✅ `kubeVersion: >=1.28.0-0` |
| `golift/unpackerr` image | `0.15.2` | **`0.15.2` (no change)** | ✅ |

### Rationale

- **Chart 4.6.2 → 5.1.0:** `5.1.0` is the latest release of the BJW-S app-template chart.
  Its declared `kubeVersion` is `>=1.28.0-0`, so it is fully compatible with the live
  1.28.1 cluster. There is no newer chart than `5.1.0`.
- **Image 0.15.2 stays:** According to the `golift/unpackerr` registries (Docker Hub /
  GHCR), the newest release tag is **0.15.2** — which is exactly what this app already
  pins. There is currently no newer stable release to move to, so the image requires no
  change.

### Newest overall vs. target

- Newest chart overall: `5.1.0` — **recommended** (nothing skipped; it is 1.28-compatible).
- Newest image overall: `0.15.2` — already deployed. A rolling `latest` tag exists that
  tracks the current stable, but we recommend keeping the explicit, reproducible `0.15.2`
  pin rather than moving to a floating tag (see Notes below).

## Breaking changes / migration notes

### Chart `4.6.2 → 5.1.0` (major `4→5` upgrade)

The `app-template` 5.x line is a major chart rewrite. Key breaking changes relevant here:

- **Requires k8s 1.28+** — the live cluster (1.28.1) meets this. Local `helm template` /
  `kustomize build` run on a machine where helm defaults its kubeVersion check to 1.27 may
  print `incompatible with Kubernetes v1.27.0`. This is a **render-time-only** artifact of
  the local tool defaulting; the live API server is 1.28.1 and satisfies `>=1.28.0-0`.
  Render with `--kube-version 1.28.1` (or `helm`/kustomize `--kube-version`) to silence,
  or confirm via `kubectl version --server`.
- **Removed/deprecated values:** `global.*` block removed (values moved to top-level),
  `image.digest` / legacy `image` fields consolidated, some `additionalContainers` /
  `initContainers` schemas moved under `controllers.<name>.containers`, `persistence`
  global mounts consolidated into `globalMounts`/`advancedMounts`. **This app does not use
  any of the removed fields** (it uses `image.repository/tag`, `env`, `probes`,
  `defaultPodOptions.securityContext`, `service.enabled:false`, `persistence.type:
  nfs` + `advancedMounts`), all of which remain supported in 5.x.
- **Probes/health:** probe schema is unchanged for the simple `enabled:false` form used here.
- **SecurityContext:** `defaultPodOptions.securityContext` is still supported; no change
  needed for the `runAsNonRoot`/`runAsUser:1000`/`fsGroup` settings.
- **Persistence (NFS):** `type: nfs` + `server`/`path` + `advancedMounts` remain supported;
  no migration needed.

**Because the migration mostly removed deprecated fields this app does not use, this is
expected to be a drop-in chart bump.** Still verify by rendering and dry-running before
apply (see steps).

### Image `0.15.2` (no change)

No image-level breaking changes to plan for, since we are staying on the current latest
release. If a future `0.16.x` lands, review the golift/unpackerr release notes for env /
config churn before upgrading.

## Step-by-step upgrade plan (chart only)

1. **Confirm current live state (optional but recommended):**
   ```bash
   kubectl -n unpackerr get deploy,statefulset,pods -o wide
   ```
2. **Edit `kustomization.yaml`** — bump the chart version:
   ```yaml
   helmCharts:
     - name: app-template
       releaseName: unpackerr
       namespace: unpackerr
       version: 5.1.0          # was 4.6.2
       repo: https://bjw-s-labs.github.io/helm-charts
       valuesFile: values.yaml
   ```
3. **(No edit needed)** `values.yaml` image.repo/tag stays `golift/unpackerr` / `0.15.2`.
4. **Render to confirm** the chart inflates cleanly and matches live k8s version:
   ```bash
   cd nauvoo-v2/manifests/apps/unpackerr
   kustomize build --kube-version 1.28.1 . >/dev/null   # expect success
   kubectl apply --dry-run=client -k .
   ```
5. **Apply** (this repo is ArgoCD-managed at the `nauvoo-v2/manifests/apply` level; normal
   path is commit + push and let ArgoCD sync):
   ```bash
   kubectl apply -k .
   # or push to git and let ArgoCD sync the unpackerr app
   ```
6. **Watch rollout.**
   ```bash
   kubectl -n unpackerr rollout status deploy/unpackerr --timeout=300s
   ```

## Rollback plan

- **Revert the `kustomization.yaml` `version` back to `4.6.2`** (and any `values.yaml`
  change, none here) and re-apply / `git revert` + ArgoCD sync.
- If ArgoCD syncs from git, roll forward by restoring the prior commit; the app-template
  `4.x` chart remains available in the repo, so rollback is a simple version revert.
- The app is stateless (config on NFS `/downloads`); no data migration is performed by the
  chart bump, so rollback is low-risk.

## Post-upgrade verification

- `kubectl -n unpackerr rollout status deploy/unpackerr --timeout=300s` → success.
- `kubectl -n unpackerr get pods -o wide` → pod `Running`/`Ready`.
- `kubectl -n unpackerr logs deploy/unpackerr --tail=50` → expects unpackerr to connect to
  Sonarr/Radarr (no auth/API errors) and show the `UN_LOG_FILE` path `/downloads/unpackerr.log`.
- Confirm the NFS share is mounted: `kubectl -n unpackerr exec deploy/unpackerr -- ls -la /downloads`.
- Confirm Sonarr/Radarr connectivity in logs (both API keys resolved from the
  `unpackerr-arr-keys` sealed secret).

## Notes / floating-tag call-out

- The deployment pins the image to the exact release `0.15.2` (good — deterministic). A
  floating `latest` tag also exists upstream; **keep the pinned `0.15.2`** rather than
  switching to `latest` so upgrades are intentional and reproducible.
- The `0.15.2` pin is already the newest stable release as of this plan, so no image change
  is warranted right now. Re-run a registry check before a future image bump (0.16.x etc.).
