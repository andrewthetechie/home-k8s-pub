# OmniRoute — Upgrade Plan

> **Scope:** Plan only. No manifests/config are changed by this document except the
> `UPGRADE_PLAN.md` file itself. Chart/image version bumps below are recommendations for a
> later, separate change.
>
> **Cluster constraint:** Kubernetes is pinned at **v1.28.1** and **cannot be upgraded**.
> Every recommended target below was verified against this constraint.

## Current state

| Component | Value | Where pinned |
|-----------|-------|--------------|
| Chart: `app-template` (bjw-s-labs) | **4.6.2** | `kustomization.yaml` → `helmCharts[0].version` |
| App image: `diegosouzapw/omniroute` | **3.8.49** | `values.yaml` → `controllers.omniroute.containers.app.image.tag` |
| Redis sidecar | `redis:7-alpine` | `redis.yaml` (may float on minor; see note) |

**Overall upgrade recommendation:**

1. **Chart:** `4.6.2` → **`5.1.0`** (newest, k8s 1.28-compatible) — recommended.
2. **Image:** keep **`3.8.49`** — this is already the newest **stable** release tag (`latest`
   also resolves to `3.8.49`). No image bump is available or needed.

---

## Target versions

### 1) app-template chart: 4.6.2 → 5.1.0 ✅ recommended

- **Newest overall:** `5.1.0` (index shows `5.1.0` as the latest; prior `5.0.1`, `5.0.0`).
- **kubeVersion compatibility:** `5.1.0` declares `kubeVersion: >=1.28.0-0` → **valid on k8s
  1.28.1**. (All 4.x and 5.x chart releases similarly declare `>=1.28.0-0`; nothing requires
  a newer k8s.)
- The chart/library installs **no custom CRDs**, so there is no CRD-API surface to worry
  about on 1.28.
- **Rationale:** `5.x` is the actively maintained major line; `4.x` is legacy. The `5.1.0`
  bump is safe for this app because its `values.yaml` uses only the stable, unchanged surface
  (`controllers`/`containers`/`image`/`env`/`probes`/`resources`, `defaultPodOptions`,
  `service`, `ingress`, `persistence`) — none of which changed in the 4→5 migration.

### 2) Application image: stay on 3.8.49 (already newest stable)

- Queried Docker Hub `diegosouzapw/omniroute` tags directly:
  - Versioned stable tags: newest is **`3.8.49`** (published 2026-07-30). This is the tag
    already deployed.
  - `latest` → also `3.8.49`.
  - `next` / `main` / `next-web` / `main-web` / `*-web` → **unstable/dev/branch builds**
    (2026-08-13…15) — **not** recommended for production.
- **Conclusion:** the app is **already on the newest stable image**. No tag bump is
  recommended. Continuing to pin `3.8.49` (rather than `latest`) is correct — the image is
  **already pinned**, not floating.

---

## Breaking changes / migration notes

### app-template 4.x → 5.x (chart-level)

Only three documented breaking changes in the 4-to-5 upgrade guide, **none of which affect
this app**:

1. **`rawResources` restructure** — raw resources now use a `manifest:` wrapper with
   labels/annotations nested under `metadata` and no top-level `spec` key.
   *OmniRoute does not use `rawResources`* → not applicable.
2. **Default ServiceAccount** — v5 auto-creates a dedicated unprivileged ServiceAccount named
   after the Helm release, instead of falling back to the namespace default.
   *OmniRoute doesn't configure a ServiceAccount and doesn't need the default SA token. The
   auto-created SA is unprivileged, so this is harmless.* Optional opt-out:
   `global.createDefaultServiceAccount: false` (not necessary).
3. **`automountServiceAccountToken` now defaults to `false`** — pods no longer auto-mount the
   SA token.
   *OmniRoute talks to Redis over the cluster network and its external API only; it does not
   use the Kubernetes API, so it doesn't need the token.* Not applicable.

No values-schema renames affect `controllers`, `service`, `ingress`, `persistence`, or
`defaultPodOptions` as used here, so the existing `values.yaml` is expected to render correctly
on 5.1.0 unchanged.

### Application image 3.8.x (no change recommended)

No image upgrade is being proposed, so no image-level migration steps are required. (If, in
the future, you pull an unstable `next`/`main` build to test upcoming features, treat it as a
manual, freezable experiment — do **not** leave the deployment on a dev tag.)

---

## Step-by-step upgrade plan

Only the **chart version** is bumped. Apply when ready (separate from planning):

1. **Pre-flight snapshot**
   - `kubectl -n omniroute get deploy,sts,pvc,svc,ingress,sealedsecret -o yaml > /tmp/omniroute-before-$(date +%F).yaml`
   - Note the current chart-rendered state: `helm template` equivalent via
     `kubectl kustomize .../omniroute` (capture for diffing after upgrade).

2. **Bump the chart version** in `kustomization.yaml`:
   ```yaml
   helmCharts:
     - name: app-template
       releaseName: omniroute
       namespace: omniroute
       version: 5.1.0        # was 4.6.2
       repo: https://bjw-s-labs.github.io/helm-charts
       valuesFile: values.yaml
   ```

3. **Re-render / dry-run**
   - `kubectl kustomize .../omniroute > /tmp/omniroute-5.1.0.yaml`
   - Diff against the captured pre-upgrade render. Confirm only expected changes (image stays
     `3.8.49`, ServiceAccount `omniroute` added, token auto-mount off, no `rawResources`).
   - Reconcile the ArgoCD app (or apply with `kubectl apply --dry-run=server -f` against the
     rendered manifest) to catch API/validation errors before rollout.

4. **Roll out (RollingUpdate)**
   - Trigger ArgoCD sync (this app is managed by the ArgoCD appset) or `kubectl apply` the
     rendered manifests.
   - Monitor rollout: `kubectl -n omniroute rollout status deploy/omniroute`.

5. **Verify** (see Post-upgrade verification).

> Note: the Redis sidecar (`redis.yaml`) is a separate raw Deployment feeding
> `REDIS_URL`. It is unchanged by this plan. If desired, future maintenance could pin Redis
> to a concrete tag instead of `7-alpine`, but that is out of scope here.

---

## Rollback plan

- **Chart rollback:** revert `version: 5.1.0` → `4.6.2` in `kustomization.yaml`, re-render,
  and re-sync via ArgoCD (or re-apply). Both chart majors are k8s 1.28-compatible, so
  rollback is a clean manifest swap.
- **Data safety:** OmniRoute persists under `/app/data` on the `data` PVC
  (`freenas-iscsi-ssd-csi`, RWO, 5Gi) — untouched by a chart-level bump. No PV/PVC change.
- **Secrets:** `omniroute-secrets` (sealed) and `STORAGE_ENCRYPTION_KEY` are unaffected.
- **Image:** unchanged at `3.8.49`, so no image rollback phase exists.

---

## Post-upgrade verification

- `kubectl -n omniroute get pods,deploy` → `omniroute` Deployment `Ready 1/1`; Redis pod ready.
- Rollout health:
  `kubectl -n omniroute rollout status deploy/omniroute`
- Probe endpoints pass (chart probes are derived from the app values):
  - Liveness/readiness/startup: `GET /api/monitoring/health` (HTTP 200).
- Ingress/TLS: `curl -sI https://omniroute.herrington.services/api/monitoring/health` returns
  200; cert-manager secret `omniroute-tls` is valid/renewing.
- App functional check (manual): log in (OAuth callback against
  `NEXT_PUBLIC_BASE_URL`/`BASE_URL`), confirm a route/LLM request round-trips, confirm Redis
  rate-limiter key present (shared cache/limiter working).
- Confirm the new auto-created ServiceAccount `omniroute` exists and the pod shows
  `automountServiceAccountToken: false` if you want the tightened posture
  (`kubectl -n omniroute get sa omniroute`).

---

## Residual risks / notes

- **Chart 4.x → 5.x is a major line change.** Although no documented breaking change applies
  to these values, verify the rendered diff carefully (step 3) before rollout — a hidden
  default change could surface.
- **`next`/`main` tags are the future 3.9+ line** and are newer than `3.8.49` but unstable;
  they are intentionally not recommended. Revisit the stable tag after the next stable
  release ships.
- **Redis tag (`redis:7-alpine`)** is a floating minor tag in a separate manifest; unrelated
  to this upgrade but worth pinning in a future task.
