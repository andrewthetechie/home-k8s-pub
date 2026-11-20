# UPGRADE_PLAN — rtlsdr (namespace: rtl)

This folder runs two SDR-based receiver workloads, each a single-replica `StatefulSet`
using **custom/personal container images** published to GHCR by the homelab owner
(`andrewthetechie`, the repo operator). These images have no conventional "semver
release" cadence — each tag embeds the short SHA of the source commit the CI build
was produced from, and there is also a floating `main` / `...latest` tag per build.

| Workload   | StatefulSet file          | Image (current)                                        |
|------------|---------------------------|--------------------------------------------------------|
| APRS iGate | `statefulset-aprs.yaml`   | `ghcr.io/andrewthetechie/docker-direwolf:rtlsdrblog9e4a585` |
| rtl_433    | `statefulset-rtl433.yaml` | `ghcr.io/andrewthetechie/rtl_sdr_static:librtlsdr86c6f8f`   |

> K8s constraint: cluster is **Kubernetes v1.28.1** and cannot be upgraded. Both
> workloads are `apps/v1` StatefulSets using `privileged` securityContext, `hostPath`
> device mounts, and nodeAffinity on USB-device feature labels. None of these depend
> on any k8s API that was removed after 1.28, so the image upgrades below are fully
> compatible with the current cluster. See "Compatibility" section.

---

## 1. Current version

- **APRS (direwolf):** `ghcr.io/andrewthetechie/docker-direwolf:rtlsdrblog9e4a585`
  - Image build date: **2024-01-04** (revision `9e4a58580228240bc...`)
  - Bundled binaries (verified by running the image):
    - Direwolf **1.7** (repo ARG is pinned to `DIREWOLF_VERSION=1.7`, unchanged across builds)
    - `rtl_fm` / `rtl_433` **version 23.11** (built 2023-11-28) — from the older `rtl_sdr_static` base
- **rtl_433:** `ghcr.io/andrewthetechie/rtl_sdr_static:librtlsdr86c6f8f`
  - Image build date: **2024-04-25** (revision `86c6f8f8402755c18...`), `org.opencontainers.image.version: librtlsdrmain`
  - Bundled: `rtl_433` **master** built 2024-04-23, static-linked against **librtlsdr** drivers

---

## 2. Target version (newest compatible with Kubernetes 1.28)

| Workload | Current tag            | Target tag                 | Rationale |
|----------|------------------------|----------------------------|-----------|
| APRS     | `...:rtlsdrblog9e4a585`| **`...:rtlsdrblog1b802b3`** | Newest `rtlsdrblog*` build (2024-11-23); equals `rtlsdrbloglatest`/`main`. Direwolf stays 1.7, but bundled `rtl_fm`/`rtl_433` update to master (2024-04-23). |
| rtl_433  | `...:librtlsdr86c6f8f` | **no change (already latest)** | This is the newest `librtlsdr*` build and equals `librtlsdrlatest`/`main`. No newer tag exists to move to. |

**APRS only:** `rtlsdrblog9e4a585` (2024-01-04) → `rtlsdrblog1b802b3` (2024-11-23).

The target was determined by querying the GHCR tag list and comparing image
`Created` timestamps (via manifest config blobs) to identify the newest
`rtlsdrblog*` / `librtlsdr*` build for each image, then verifying bundled binary
versions by pulling and running the images with Docker.

---

## 3. Newest overall version — is anything skipped?

- **docker-direwolf:** `rtlsdrblog1b802b3` IS the newest build (it is what the
  floating `rtlsdrbloglatest` / `rtlsdrblogmain` tags point to, build 2024-11-23).
  Nothing beyond it is available. **Not skipped.**
- **rtl_sdr_static:** `librtlsdr86c6f8f` is the newest `librtlsdr*` build (equals
  `librtlsdrlatest` / `librtlsdrmain`, build 2024-04-25). There is no newer tag.
  **Nothing to skip — already current.**

These are small, single-owner hobby images with no major-version/release train; there
is no "latest-but-incompatible" version to reject. The only meaningful newer asset is
the APRS container's updated `rtl_433`/`rtl_fm` toolchain.

---

## 4. Breaking changes / migration notes

- **Direwolf 1.7 → 1.7:** No application-version change. The `direwolf.conf` ConfigMap
  (`configmap-direwolf.yaml`), CLI args in `statefulset-aprs.yaml`
  (`rtl_fm -f 144.39M | direwolf -t 0 -d ii -d ff -c ... -n 1 -r 24000 -`), and the
  config-mount paths (`/etc/direwolf`, `/dev/rtl`) are unchanged and remain valid.
  None of the Direwolf 1.7 options used are deprecated.
- **rtl_433 23.11 → master (2024-04-23):** Update within the rtl_433 feature set.
  The rtl_433 StatefulSet pins its own (already-latest) image and is **not** being
  changed. The APRS container's bundled `rtl_fm`/`rtl_433` update is not consumed by
  the running command (the APRS pod runs `rtl_fm` + `direwolf`, not `rtl_433`), and
  `rtl_fm`'s interface is stable — no config impact.
- **rtl_433.conf** (`configmap-rtl433.yaml`) is consumed by the rtl_433 StatefulSet,
  which keeps `librtlsdr86c6f8f`. No change, so the frequency/protocol directives are
  indifferent to this upgrade.
- **No k8s API / schema impact:** both files are `apps/v1 StatefulSet` with
  `privileged`, `hostPath` volumes, and `nodeAffinity` — all supported on 1.28.
  Node-affinity feature labels (`feature.node.kubernetes.io/usb-ff_0bda_2838_*.present`)
  are unchanged.
- **Version-string artifact (non-blocking):** the newer `rtl_433` prints
  `version -128-NOTFOUND branch master` — this is only a cosmetic packaging defect in
  how `RTL_433_VERSION` is baked into the image (the real `master` date 2024-04-23 is
  shown). It does not affect function and is an upstream image-build quirk, noted for
  awareness only.

---

## 5. Step-by-step upgrade plan

Prereq: image changes are only applied the next time `kustomize build` + `kubectl apply`
run for this namespace (and ArgoCD if this app is synced) — **no code-level migration**.

1. **APRS (only change):** in `statefulset-aprs.yaml`, change
   `image: ghcr.io/andrewthetechie/docker-direwolf:rtlsdrblog9e4a585`
   to
   `image: ghcr.io/andrewthetechie/docker-direwolf:rtlsdrblog1b802b3`
   (recommend pinning the commit tag, consistent with the existing repo convention,
   rather than switching to the floating `rtlsdrbloglatest`).
2. **rtl_433:** leave `statefulset-rtl433.yaml` unchanged
   (`librtlsdr86c6f8f`) — already at the newest build.
3. Validate the kustomize build renders cleanly:
   `kubectl kustomize /Users/andrew/Documents/code/home-k8s/nauvoo-v2/manifests/apps/rtlsdr`
4. Apply: `kubectl apply -k .../rtlsdr` (or sync via ArgoCD for the `rtl` app if managed).
5. Confirm the APRS StatefulSet rolls: `kubectl -n rtl rollout status statefulset/aprs`.

> Optional hardening (note, not part of this upgrade): both images are custom and
> could be repointed to a floating `*latest` tag for auto-updates, but the repo
> convention pins commit SHAs for reproducibility — keep the pinned tag unless you
> deliberately want rolling updates.

---

## 6. Rollback plan

- **APRS:** revert `statefulset-aprs.yaml` image to `rtlsdrblog9e4a585` and re-apply.
  Old and new images are both Direwolf 1.7, so rollback is low-risk and immediate
  (`kubectl -n rtl rollout restart statefulset/aprs` after reverting).
- **rtl_433:** no change made, so nothing to roll back.
- Verify the previously mirrored Direwolf config and APRS decode output return to
  normal before considering the change reverted.

---

## 7. Post-upgrade verification

- `kubectl -n rtl get statefulset aprs rtl433` — check `READY 1/1` and
  `CURRENT`/`UPDATED` revisions match.
- `kubectl -n rtl logs statefulset/aprs -c aprs --tail=50` — confirm:
  - Direwolf starts with **"Dire Wolf version 1.7"**,
  - `rtl_fm` opens `rtlsdrblog` device (no USB open errors),
  - the IGate connects to `noam.aprs2.net` and decodes packets.
- `kubectl -n rtl logs statefulset/rtl433 -c rtl433 --tail=50` — confirm rtl_433 starts,
  opens `/dev/rtl`, and emits JSON to the configured MQTT broker
  (`mosquitto.mqtt.svc.cluster.local:1883`); spot-check weather-sensor packets
  (Acurite/Thermopro/Inkbird) in MQTT.
- Confirm the rtl_433 SDR dongle (`/dev/rtlsdr103` node) and APRS dongle
  (`/dev/rtl`, feature label `usb-ff_0bda_2838_0000010x`) stayed on their pinned nodes
  (nodeAffinity satisfied).
- Confirm no new ERROR/CRIT logs after rollout settles.

---

## Summary (current → target)

- **APRS direwolf:** `rtlsdrblog9e4a585` → **`rtlsdrblog1b802b3`** (Direwolf stays 1.7;
  newer bundled `rtl_fm`/`rtl_433` toolchain). Fully k8s 1.28-compatible.
- **rtl_433:** already at latest (`librtlsdr86c6f8f`) — **no change required.**
