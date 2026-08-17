# Sealed-Secrets Upgrade Plan

- **Date:** 2026-08-16
- **Cluster:** Kubernetes v1.28.1 (Talos v1.5.5) — **cannot be upgraded right now**
- **Management:** Helm chart rendered via `kustomize` (`helmCharts`), deployed by ArgoCD AppSet
- **Manifest location:** `nauvoo-v2/manifests/infra/sealed-secrets/`
- **Namespace:** `kube-system`

---

## 1. Current Version

| Component | Version | Location |
|---|---|---|
| Helm chart | **2.12.0** | `kustomization.yaml` → `helmCharts[].version`, vendored copy `charts/sealed-secrets/Chart.yaml` |
| Controller image | **docker.io/bitnami/sealed-secrets-controller:v0.23.1** | chart `appVersion` / `image.tag` |
| CRD API | `sealedsecrets.bitnami.com/v1alpha1` | `includeCRDs: true` |

---

## 2. Target Version (Recommended)

| Component | Version |
|---|---|
| Helm chart | **2.17.0** |
| Controller image | **docker.io/bitnami/sealed-secrets-controller:0.27.3** |

### Why 2.17.0 / v0.27.3 is the ceiling for this cluster

The chart itself declares `kubeVersion: ">=1.16.0-0"` in **every** released version (no upper bound), so the chart never blocks installation on v1.28. **The real binding constraint is the controller's `client-go` dependency relative to the v1.28 API server**, per the Kubernetes [version skew policy](https://kubernetes.io/releases/version-skew-policy/) (clients are supported within ~N±1 of the API server).

| Controller | client-go | Target k8s | Skew from 1.28 | Verdict |
|---|---|---|---|---|
| v0.23.1 (current) | v0.27.4 | 1.27 | N−1 | inside skew |
| **v0.27.3 (target)** | **v0.30.2** | **1.30** | **N+2** | **last safe-ish jump — last version before client-go leaps to 0.32** |
| v0.28.0+ | v0.32.0 | 1.32 | N+4 | **outside reasonable skew — not recommended on 1.28** |
| v0.38.4 (latest) | v0.36.2 | 1.36 | N+8 | **NOT for a 1.28 cluster** |

**Key reasoning:**
- `v0.28.0` is the first release that bumps `client-go` from `v0.30.x` to `v0.32.0` (k8s 1.32), a 4-minor-version jump ahead of the 1.28 server. `v0.27.3` is the highest controller **before** that jump.
- The Sealed Secrets project's own README states it CI-verifies every release against clusters ≥1.24, so `v0.27.3` (client-go 1.30, N+2) is within the range the project actually tests.
- **Do NOT use the latest `v0.38.4` / chart `2.19.1` here.** It ships `client-go v0.36.2` (k8s 1.36) — 8 minor versions ahead of a 1.28 API server. That is outside any supported skew and is exactly the kind of mismatch that can break on an un-upgradable cluster.

> **Strictly-policy-compliant alternative:** if you prefer to stay within the official N±1 skew, use **chart 2.15.2 / controller v0.26.1** (`client-go v0.29.2`, k8s 1.29, N+1). The recommended 2.17.0/v0.27.3 at N+2 is a pragmatic, widely-used middle ground.

---

## 3. Kubernetes Compatibility Matrix

Chart `kubeVersion` constraints for reference (all versions share the same constraint):

| Chart version | Controller | `kubeVersion` constraint | Works on 1.28? |
|---|---|---|---|
| 2.12.0 (current) | v0.23.1 | `>=1.16.0-0` | ✅ (client-go 1.27) |
| 2.14.0 | v0.24.5 | `>=1.16.0-0` | ✅ |
| 2.15.2 | v0.26.1 | `>=1.16.0-0` | ✅ (client-go 1.29, N+1) |
| **2.17.0 (target)** | **v0.27.3** | **`>=1.16.0-0`** | ✅ (**client-go 1.30, N+2 — ceiling**) |
| 2.17.1 | v0.28.0 | `>=1.16.0-0` | ⚠️ client-go 1.32 (N+4) |
| 2.18.6 | v0.37.0 | `>=1.16.0-0` | ⚠️ client-go 1.36 |
| 2.19.1 (latest) | v0.38.4 | `>=1.16.0-0` | ⚠️ client-go 1.36 (N+8) |

**Bottom line:** the chart constraint is never the limiter; the controller's `client-go` is. `2.17.0` is the highest chart whose controller keeps `client-go` within practical skew of 1.28.

---

## 4. Breaking Changes / Notes to Be Aware Of

### 4.1 No "v2 API" — the CRD API is unchanged
There is **no `v2` API** for SealedSecrets. The CRD remains `sealedsecrets.bitnami.com` with API version `v1alpha1` across all versions. The encryption scheme (RSA, master key → cert) is unchanged. Existing `SealedSecret` CRs remain fully valid — **no re-encryption is needed** (see §6).

### 4.2 Image tag format change
- Current: `v0.23.1` (**`v` prefix**)
- Target: `0.27.3` (**no `v` prefix**)
Newer charts dropped the `v` prefix on `image.tag`. This is cosmetic but matters if you pin the tag explicitly.

### 4.3 `--update-status` flag (introduced ~v0.30/0.31, defaults `true`)
The controller now writes to the `status` subresource of each `SealedSecret` it processes (defaults to `true`; toggle via the `updateStatus` chart value). This:
- Requires the controller's RBAC to allow `update` on `sealedsecrets/status` — the chart handles this automatically.
- **Does not** change how existing sealed secrets are decrypted. It only adds a status condition (`Synced`), which is reflected in the CRD's printer column `Status`.
- If your ArgoCD `valuesInline` previously omitted it, the new default (`true`) applies. No action required unless you want it off.

### 4.4 Chart publication / source
The chart is published by **bitnami-labs** at `https://bitnami-labs.github.io/sealed-secrets` (already the `repo` in your `kustomization.yaml`). The controller image is `docker.io/bitnami/sealed-secrets-controller` (already in use). No source/repo change is required.

### 4.5 `--accept-deprecated-v1-data` (defaults `true`)
The controller accepts the deprecated `data` field in addition to `encryptedData`. Default is `true` in the target, matching current behavior — no change for existing CRs.

### 4.6 Chart values-structure additions (backward compatible)
The 2.17.0 `values.yaml` adds new keys (`updateStatus`, `keyttl`, `keycutofftime`, `watchForSecrets`, `metrics.prometheusRule`, `rbac.serviceProxier`, `securityContext`/`seccompProfile`, `containerPorts`, etc.). All are additive with sane defaults; the existing `valuesInline.fullnameOverride: sealed-secrets-controller` remains valid. No existing values need renaming.

### 4.7 Sealing-key naming convention (unchanged)
Sealing keys are normal k8s Secrets in `kube-system`, named `sealed-secrets-key<generation>`, labeled `sealedsecrets.bitnami.com/sealed-secrets-key: active`. The controller reads existing keys on startup rather than regenerating them — this is what preserves decryptability across upgrades.

---

## 5. Upgrade Procedure (kustomize + helm, ArgoCD AppSet)

### Preconditions
- [ ] Cluster k8s 1.28.1 — do **not** upgrade the cluster during this change.
- [ ] Back up the sealing key Secret in `kube-system`:
  ```bash
  kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml \
    > sealed-secrets-key-backup.yaml
  ```
- [ ] Record the current cert fingerprint (proves the key is unchanged after upgrade):
  ```bash
  kubeseal --fetch-cert --controller-namespace=kube-system | openssl x509 -noout -fingerprint
  ```
  (Save the output for comparison in verification.)

### Steps

1. **Bump the chart version** in `nauvoo-v2/manifests/infra/sealed-secrets/kustomization.yaml`:
   ```yaml
   helmCharts:
     - name: sealed-secrets
       releaseName: sealed-secrets
       namespace: kube-system
       version: 2.12.0   →   2.17.0
       includeCRDs: true
       repo: https://bitnami-labs.github.io/sealed-secrets
       valuesInline:
         fullnameOverride: sealed-secrets-controller
   ```
   *(No `valuesInline` changes needed — `fullnameOverride` is unchanged. Optionally add `updateStatus: true` explicitly for clarity.)*

2. **Refresh the local vendored chart copy** (`charts/sealed-secrets/`) for reference/offline consistency:
   ```bash
   helm pull bitnami-labs/sealed-secrets --version 2.17.0 --untar --destination /tmp/ss-chart
   # or: kustomize fetch from the repo on next build
   ```
   Keep the vendored copy in sync with `kustomization.yaml` (kustomize's `helmCharts` with `repo`/`version` fetches the remote chart at build time; the local dir is a reference copy).

3. **Render and diff locally** (dry-run before committing):
   ```bash
   kustomize build nauvoo-v2/manifests/infra/sealed-secrets > /tmp/ss-rendered.yaml
   ```
   Verify: controller Deployment image is `...:0.27.3`, CRD present, `updateStatus` flag set, no unexpected deletions.

4. **Commit and push** — ArgoCD AppSet (`argocd/appset-infra.yaml`, path `nauvoo-v2/manifests/infra/sealed-secrets`) will detect the change. Sync wave for this app is `0` (non-kyverno/actions-runner), so it applies normally.

5. **ArgoCD sync** (or let auto-sync apply):
   ```bash
   argocd app sync sealed-secrets
   argocd app wait sealed-secrets
   ```

6. **Confirm the sealing key was NOT regenerated** (critical):
   ```bash
   kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active
   kubeseal --fetch-cert --controller-namespace=kube-system | openssl x509 -noout -fingerprint
   ```
   The fingerprint must **match** the pre-upgrade value. If it differs, the key was lost/rotated and existing secrets need re-encryption (see §6) — this would be a problem to stop and fix.

---

## 6. Critical Concern: Existing SealedSecret CRs Must Stay Decryptable

**Conclusion: NO re-encryption is required for this upgrade — as long as the sealing key is retained and no cert rotation happens.**

- Existing `SealedSecret` CRs (e.g. `external-dns/sealed-secret-pihole-creds.yaml`, `cert-manager/sealed-secret-zerossl.yaml`, `argocd/sealed-secret-repo.yaml`, and others across `apps`/`infra`) are encrypted with the **public cert derived from the master sealing key** stored in `kube-system`.
- The upgrade to `v0.27.3` does **not** change the crypto scheme, does **not** rotate the key, and does **not** introduce a new cert. The controller reads the existing `sealed-secrets-key<generation>` Secret on startup and keeps using it. **All existing CRs remain decryptable.**
- Re-encryption (`kubeseal --re-encrypt`) is **only** necessary if the sealing key is ever deleted/rotated (key loss, cluster rebuild, or deliberate key rotation). This upgrade performs neither.

### Guardrails
- **Never delete** the `sealed-secrets-key*` Secrets in `kube-system` during or after the upgrade.
- If the cert fingerprint changes after sync, **halt immediately** and restore the backed-up key Secret before ArgoCD propagates further.
- Do not combine this upgrade with a key-renewal/rotation exercise. Treat them as separate, deliberately scheduled operations.

---

## 7. Verification Steps

1. **Deployment healthy**
   ```bash
   kubectl -n kube-system get deploy sealed-secrets-controller -o wide
   kubectl -n kube-system get pods -l app.kubernetes.io/name=sealed-secrets -o wide
   ```
   Image should read `bitnami/sealed-secrets-controller:0.27.3`, pod `Running`/`Ready 1/1`.

2. **Cert fingerprint unchanged** (see §5 step 6) — the single most important check.

3. **Sealing key Secret still present & unmodified**
   ```bash
   kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o name
   ```

4. **Existing SealedSecrets still reconcile**
   ```bash
   kubectl -n kube-system get sealedsecrets -A
   # verify Status condition shows Synced and no decrypt errors in controller logs
   kubectl -n kube-system logs -l app.kubernetes.io/name=sealed-secrets | grep -i "error\|fail"
   ```

5. **Spot-check a decrypted value** (optional, read-only proof):
   ```bash
   kubectl -n cert-manager get secret zerossl --context ...  # or use kubeseal to re-seal a known value
   kubeseal --fetch-cert --controller-namespace=kube-system | openssl x509 -noout -fingerprint
   ```

6. **ArgoCD health**: `argocd app get sealed-secrets` shows `Healthy`/`Synced`.

---

## 8. Rollback Plan

Rollback is trivial because the change is a single `version` bump and the CRD/SealedSecrets are backward-compatible.

1. **Revert** `kustomization.yaml`: `version: 2.17.0` → `2.12.0`, commit, push. ArgoCD reverts the Deployment to `v0.23.1`.
2. **If the newer chart upgraded the CRD** (added `status`/printer columns), the old controller still works — CRD schema changes are additive and non-breaking.
3. **If the cert fingerprint changed** (key lost): do **not** roll back the controller alone — restore the backed-up `sealed-secrets-key*` Secret from §5 preconditions, then roll back the chart. Existing CRs decrypt immediately once the original key is back.
4. **Verify after rollback**: controller `v0.23.1` running, cert fingerprint matches the original, all SealedSecrets `Synced`.

---

## 9. Summary

- **Upgrade:** chart `2.12.0` → `2.17.0`, controller `v0.23.1` → `v0.27.3`.
- **Why this ceiling:** `v0.27.3` is the highest controller whose `client-go` (1.30) stays within practical skew of the un-upgradable k8s 1.28 API server; the next release (`v0.28.0`) jumps `client-go` to 1.32. The latest `v0.38.4`/chart `2.19.1` (client-go 1.36) is **not** suitable for 1.28.
- **No re-encryption needed:** the sealing key (master key) and its cert are retained; the crypto scheme and CRD API (`v1alpha1`) are unchanged. All existing SealedSecret CRs remain decryptable.
- **Primary risk:** accidental sealing-key loss/rotation — mitigated by backing up the key Secret and verifying the cert fingerprint before/after.
