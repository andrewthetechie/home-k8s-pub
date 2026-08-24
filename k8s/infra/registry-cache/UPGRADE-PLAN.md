# Upgrade Plan: registry-cache → registry:3.1.1

**Date:** 2026-08-16 (upgrade date to be confirmed before execution)
**Author:** homelab ops
**Cluster:** Kubernetes v1.28.1 / Talos v1.5.5 — no cluster upgrade involved
**Scope:** `nauvoo-v2/manifests/infra/registry-cache/` (ArgoCD-managed kustomize static manifests)

---

## 1. Current version

- All four registry Deployments run `image: registry:2.8.3` (docker/distribution):
  - `registry-dockerhub.yaml:18`
  - `registry-ghcr.yaml:18`
  - `registry-local.yaml:18`
  - `registry-mcr.yaml:21`
- The wipe executor Jobs use `busybox:1.36` (independent of the registry image) and are **not** affected by this upgrade.
- Storage is filesystem (`REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry`) on RWO iSCSI PVCs (`freenas-iscsi-csi`, 200Gi). Data is disposable.

### Security: 2.8.3 is the last 2.8.x and is vulnerable

The docker/distribution **2.8.x line is end-of-life; there is no 2.8.4+ patch**. The security fixes were only released in 3.x. Known CVEs affecting 2.8.3:

| CVE | Severity | Description |
| --- | --- | --- |
| CVE-2024-41131 | High | Authorization bypass: unauthenticated requests to `/v2/<name>/(tags|manifests)/` are not checked against auth, allowing access to private image data. |
| CVE-2024-41129 | High | Path traversal in blob storage (`GetBlob`/`PutBlob`): a malicious manifest can read arbitrary files from the registry host (e.g. `/etc/shadow`). |
| CVE-2024-41130 | Medium | DoS: crafted image manifests cause excessive memory consumption, crashing the registry process. |

These were disclosed 2024-08 and are fixed only in 3.0.0+. Because these registries are pull-through caches used cluster-wide (docker.io, ghcr.io, mcr.microsoft.com) and the local buildx cache target, an attacker who can reach the registry service (or who can push a malicious manifest into the cache path) can exploit the path-traversal/auth-bypass bugs. This is the driver for the upgrade.

---

## 2. Target version

**`registry:3.1.1`** (latest stable, confirmed on Docker Hub tag list; 3.x line: 3.0.0 → 3.1.0 → 3.1.1).

### Why 3.1.1
- Contains the fixes for CVE-2024-41131 / 41129 / 41130 (3.0.0+).
- Latest stable release; 3.1.1 is the current head of the 3.x line.
- Kubernetes compatibility is trivial — the registry is just a container; it uses no Kubernetes APIs. Verified running on a container runtime with no cluster-version constraints. (K8s v1.28.1 does not need to change.)

### Verified drop-in compatibility
`registry:3.1.1` was run locally with **exactly** the env vars used in the current manifests:
- `REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io` → logged `"Registry configured as a proxy cache"` and discovered the Docker token auth endpoint.
- `REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry` → used the `filesystem` storage driver, started listening on :5000, served `/v2/`.

So no manifest changes beyond the image tag are strictly required.

---

## 3. Breaking changes: 2.8.3 → 3.1.1

| Area | Change | Impact on this repo |
| --- | --- | --- |
| 2.8.x line | EOL — no 2.8.4+ backports. | Must move to 3.x to get CVE fixes. |
| Storage driver config | 3.x restructured storage config and removed the in-memory storage driver (a real driver is now required). `REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY` still works (verified). | No change needed; filesystem driver is already explicit. |
| Proxy/cache config | `REGISTRY_PROXY_REMOTEURL` unchanged in 3.x (verified). | No change needed. |
| Blob descriptor cache | 3.x defaults to `inmemory` blob descriptor cache (same behavior as 2.8) — relevant because the wipe procedure relies on a registry restart to flush this cache. | Behavior preserved; restart-after-wipe still required. |
| `REGISTRY_STORAGE_DELETE_ENABLED` | Still supported (used by `registry-local` for buildx cache cleanup). | No change needed. |
| Wipe resources | Wipe is a filesystem-level `rm -rf` by `busybox:1.36` executors; it is registry-version-independent. `registry-wipe.yaml`, `registry-*-wipe.yaml`, `WIPE.md` unaffected. | No change needed. |
| `REGISTRY_HTTP_SECRET` | 3.x may be stricter about an explicitly set HTTP secret. Not required for the anonymous single-replica caches here, but see rollback notes. | Optional hardening, not required. |

Net: **only the image tag changes in each `registry-*.yaml`.**

---

## 4. Upgrade procedure

This is a static-manifests ArgoCD app (kustomize). ArgoCD manages the four Deployments. All four are disposable caches with `Recreate` strategy and RWO volumes.

### Step 0 — Preflight
```bash
# confirm the target image exists and is pullable on a cluster node
docker manifest inspect registry:3.1.1
# confirm current running image on each deployment
kubectl -n registry-cache get deploy -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.template.spec.containers[0].image}{"\n"}{end}'
```
- Confirm a recent wipe/GC has run so caches are healthy before upgrading (see WIPE.md).

### Step 1 — Edit the four Deployment manifests
Replace `image: registry:2.8.3` with `image: registry:3.1.1` in:
- `registry-dockerhub.yaml` (line 18)
- `registry-ghcr.yaml` (line 18)
- `registry-local.yaml` (line 18)
- `registry-mcr.yaml` (line 21)

Do **not** touch `registry-*-wipe.yaml`, `storage-*.yaml`, `namespace.yaml`, `kustomization.yaml`, or `registry-wipe.yaml` — they are version-independent.

### Step 2 — Commit + sync via ArgoCD
```bash
git -C ../.. add nauvoo-v2/manifests/infra/registry-cache
git -C ../.. commit -m "registry-cache: upgrade registry 2.8.3 -> 3.1.1 (CVE-2024-41129/30/31)"
git -C ../.. push
# let ArgoCD auto-sync (or force):
argocd app sync <app-name> --server-side  # or via the UI
```

### Step 3 — Rollout (ArgoCD will roll; do it manually if not)
```bash
kubectl -n registry-cache rollout restart deploy/registry-dockerhub \
  deploy/registry-ghcr deploy/registry-local deploy/registry-mcr
kubectl -n registry-cache rollout status deploy/registry-dockerhub --timeout=300s
kubectl -n registry-cache rollout status deploy/registry-ghcr       --timeout=300s
kubectl -n registry-cache rollout status deploy/registry-local     --timeout=300s
kubectl -n registry-cache rollout status deploy/registry-mcr       --timeout=300s
```
> Because these are single-replica `Recreate` deployments on RWO volumes, each rollout briefly takes the registry offline while the new pod starts. The cache is a cold-miss window only — acceptable, and it is the same behavior as the existing wipe-restart.

---

## 5. Verification

### 5.1 Image + process
```bash
kubectl -n registry-cache get deploy -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.template.spec.containers[0].image}{"\n"}{end}'
kubectl -n registry-cache get pods -l app=registry-dockerhub -o wide   # Running 1/1
kubectl -n registry-cache logs -l app=registry-dockerhub | grep -i version
```
Expect logs to report `version=3.1.1` and `Registry configured as a proxy cache`.

### 5.2 Probes healthy
Readiness/liveness probes are `GET /v2/` on :5000 — confirm all pods reach `Ready`/`Running`.

### 5.3 Pull-through still caches (proxy registries)
Pull a known manifest through each proxy and confirm real bytes come back:
```bash
kubectl -n registry-cache run cache-verify --rm -i --restart=Never \
  --image=busybox:1.36 --timeout=90s -- sh -c '
    for h in registry-dockerhub registry-ghcr registry-mcr; do
      b=$(wget -q -O /tmp/m --header="Accept: application/vnd.oci.image.index.v1+json" \
        http://$h.registry-cache.svc.cluster.local:5000/v2/library/python/manifests/3.14 \
        && wc -c < /tmp/m)
      echo "$h -> $b bytes"
    done'
```
Expect non-zero byte counts (e.g. thousands of bytes) for each — proving the cache pulls from upstream and serves.

### 5.4 Push (registry-local buildx cache target)
Run one CI/GitHub Actions workflow that uses `cache-to`/`cache-from` against `registry-local` and confirm the build completes without `short read` / zero-body errors.

### 5.5 Wipe still works (optional, scheduled)
Confirm the next weekly wipe CronJob runs cleanly (it restarts the registry to flush the in-memory descriptor cache). If unsure, follow `WIPE.md` Option A/B for a manual restart/wipe.

---

## 6. Rollback plan

All changes are a single image-tag diff, so rollback is a one-line revert per file.

1. Revert the four `registry-*.yaml` image tags back to `registry:2.8.3`.
2. Commit + push; let ArgoCD sync (or `argocd app sync`).
3. `kubectl -n registry-cache rollout restart deploy/registry-*` and wait for rollout status.
4. Re-run §5.3/§5.4 verification.

Caches are disposable — if 3.1.1 misbehaves on disk layout, follow `WIPE.md` (Option A restart first, then Option B/C full wipe) to re-warm from upstream. No data migration is involved.

Rollback triggers (any of): readiness/liveness probes failing across restarts, `/v2/` returning errors, buildkit/containerd `short read` or zero-byte `Content-Length` responses, or proxy caches failing to re-fetch from upstream after a wipe.

---

## 7. Residual risks / notes

- The 3.x line is newer and has had fewer homelab-hours of soak than 2.8.3; the wipe procedure's reliance on "restart flushes in-memory blob cache" was verified conceptually against 3.x's default `inmemory` descriptor cache but not yet exercised end-to-end on the cluster.
- `registry-local` uses `REGISTRY_STORAGE_DELETE_ENABLED` — confirm delete-enabled behavior is unchanged in 3.1.1 for the buildx cache lifecycle.
- Consider pinning `REGISTRY_HTTP_SECRET` (shared across the four Deployments) as optional hardening; not required for anonymous caches.
