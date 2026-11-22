# Standalone GitHub Actions runner box — 10.10.0.31 ("box31", host `ai-dev-env`)

**Status: DEPLOYED & VERIFIED 2026-11-22.** The canonical copies below are
authoritative (they contain fixes found during rollout); the inline listings in
this file are the original plan. See "Deployment notes" at the bottom for what
deviated and why.

This file documents the design and remains the ops runbook.

## Goal

Add CI capacity by running **2 idle workers per repo** for the 4 ARC-served repos
(`lawncare-saas`, `space-game`, `womens-fantasy-sports`, `writers-app` = **8 slots**)
on the standalone Linux host `10.10.0.31`. The box must:

- NOT become a kubelet or join the k8s cluster in any way
- never block jobs when it is offline/unreliable (ARC keeps working unchanged)
- reuse the existing GitHub App auth, runner image, buildkit, registry-local, and
  cache server so job behavior matches ARC pods as closely as possible

## How it works (design)

- Each slot is a systemd template instance `gha-runner@<repo>-<slot>` that runs one
  **ephemeral** runner cycle: mint registration token → start per-slot dind +
  buildkitd containers → register runner with label `<repo>` → run exactly one job
  → exit → systemd restarts → fresh idle worker. A slot is therefore always an
  online idle runner (like `minRunners: 1` per slot).
- Standalone runners with the same label as the ARC scale sets join the same job
  queue. GitHub assigns each job to any matching idle runner (no precedence
  guarantee); offline runners are skipped and jobs re-queue. Box dies ⇒ jobs fall
  back to ARC automatically. (Verified against GitHub's routing-precedence docs.)
- Per-slot dind (docker-in-docker) exactly like ARC pods — NOT the host docker
  daemon — because compose files publish fixed ports (80, 5432, 8080, …) that
  would collide across concurrent jobs on a shared daemon (womens playwright
  overrides publish :80/:5432/:8080/:8090; lawncare compose publishes :80/:443).
- `space-game` is Rust-only CI (no docker): its slots run a bare runner, no dind.
- Workflows hardcode `registry-local.registry-cache.svc.cluster.local:5000`
  (buildx cache refs; womens playwright **pushes images there then pulls them
  back**). The box reaches it via a new NodePort + a socat forwarder.
- Image pushes go to ghcr.io; base-image pulls go direct to the internet (the
  cluster's registry mirrors are ClusterIP-only and NOT exposed; do not use them
  in v1 — see Phase 2).

## Verified facts (do not re-research)

- Box: Ubuntu 26.04, x86_64 bare metal, i7-8650U 4c/8t, 14 GiB RAM, 4 GiB swap,
  single 476 GB NVMe root at **84% used (76 GB free)** — a prune is required.
  Docker 29.4.3 active (overlayfs), 78 images (140 GB, ~95 GB reclaimable — old
  SWE-bench eval images), 124 GB build cache (~114 GB reclaimable), 0 containers.
  Python 3.14, OpenSSL 3.5.5, chrony NTP synced, unattended-upgrades enabled.
  Nothing else runs on it (libvirtd idle). Tailscale up but irrelevant here.
- Box reaches: `actions-cache.herrington.services` (200 OK), the internet, and
  all k8s nodes directly (nodes are on its own LAN: 10.10.0.20–.25).
- `registry.herrington.services` currently 502s from everywhere (registry-images
  backend down) — irrelevant to this plan; don't touch it.
- GitHub App `home-k8s-arc-runner`: App ID **4125846**, Installation ID
  **142156219**, key in k8s secret `arc-github-app` (ns `arc-runners`, keys:
  `github_app_id`, `github_app_installation_id`, `github_app_private_key`).
  Installation covers all 4 repos. JWT→installation-token→registration-token
  flow was tested and works with bash+openssl (no pip needed).
- Runner image `ghcr.io/falcondev-oss/actions-runner:2.338.2`: stock `run.sh`
  does NOT auto-configure; `config.sh` supports `--ephemeral --labels --url
  --token`. Entrypoint override required (below).
- Workflows `runs-on:` = the repo names above (plus GitHub-hosted macos for some
  jobs). Jobs use `docker/setup-buildx-action` against `BUILDKIT_HOST`
  `tcp://127.0.0.1:1234` and `actions/cache` via the falcondev fork's
  `CUSTOM_ACTIONS_RESULTS_URL`.

## Files laid down on the box

| Path | Purpose |
|---|---|
| `/etc/gha-runner/arc-github-app.pem` | GitHub App private key (root:root 0600) |
| `/etc/gha-runner/dind-daemon.json` | per-slot dockerd config (insecure registry-local) |
| `/etc/gha-runner/buildkitd.toml` | per-slot buildkitd config |
| `/opt/gha-runner/installation-token.sh` | GitHub App → installation access token |
| `/opt/gha-runner/mint-token.sh` | repo → registration token (uses installation token) |
| `/opt/gha-runner/run-slot.sh` | one ephemeral runner cycle |
| `/etc/systemd/system/gha-registry-local-forward.service` | socat 10.10.0.31:5000 → NodePort |
| `/etc/systemd/system/gha-runner@.service` | slot template unit |
| `/var/lib/gha-runner/<instance>/` | per-slot scratch (wiped every cycle) |

Keep canonical copies of all of these in this repo under
`manifests/infra/actions-runner/standalone-box/` (ArgoCD ignores non-resource
files; SETUP.md precedent) and deploy from there.

---

## Step 0 — reclaim disk (user-confirmed 2026-11-22: proceed without asking)

The ~200 GB is old SWE-bench eval images/build cache from the box's previous life; the user has approved deleting it. Run directly:

```bash
ssh andrew@10.10.0.31
sudo docker system prune -af --volumes
df -h /   # expect roughly 280–300 GB free
```

## Step 1 — cluster: expose registry-local via NodePort

New file in this repo: `manifests/infra/registry-cache/registry-local-nodeport.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: registry-local-nodeport
  namespace: registry-cache
  labels:
    app: registry-local
spec:
  type: NodePort
  selector:
    app: registry-local
  ports:
    - port: 5000
      targetPort: 5000
      nodePort: 30500
```

Commit + push (argocd appset syncs `infra/`). Verify from the box:

```bash
curl -s http://10.10.0.20:30500/v2/   # any node IP; expect {}
```

## Step 2 — box: packages and GitHub App key

```bash
sudo apt-get update && sudo apt-get install -y jq socat
sudo mkdir -p /etc/gha-runner /opt/gha-runner /var/lib/gha-runner
# from a machine with kubectl (run there, then scp):
kubectl get secret arc-github-app -n arc-runners -o jsonpath='{.data.github_app_private_key}' \
  | base64 -d | scp - andrew@10.10.0.31:/tmp/app.pem
# on the box:
sudo install -m 0600 /tmp/app.pem /etc/gha-runner/arc-github-app.pem && rm /tmp/app.pem
sudo docker pull ghcr.io/falcondev-oss/actions-runner:2.338.2 docker:dind \
  'moby/buildkit@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8'
```

## Step 3 — box: configs

`/etc/gha-runner/dind-daemon.json` (per-slot dockerd; matches ARC dind minus the
cluster-internal mirrors and the 1370 MTU, which are Cilium-specific — box is on a
1500-MTU LAN with plain bridges):

```json
{
  "insecure-registries": [
    "registry-local.registry-cache.svc.cluster.local:5000"
  ]
}
```

`/etc/gha-runner/buildkitd.toml`:

```toml
[registry."registry-local.registry-cache.svc.cluster.local:5000"]
  http = true
```

## Step 4 — box: mint-token.sh

`/opt/gha-runner/mint-token.sh` (root 0750). Tested working 2026-11-22:

```bash
#!/usr/bin/env bash
# Print a short-lived runner registration token for andrewthetechie/<repo>,
# minted via the arc-github-app GitHub App (same app ARC uses).
set -euo pipefail
REPO="${1:?repo name}"
OWNER="andrewthetechie"
APP_ID="4125846"
INSTALLATION_ID="142156219"
KEY_FILE="/etc/gha-runner/arc-github-app.pem"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+540))" "$APP_ID" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$KEY_FILE" | b64url)
jwt="${header}.${payload}.${signature}"

installation_token=$(curl -sfS -X POST \
  -H "Authorization: Bearer ${jwt}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
  | jq -r .token)

curl -sfS -X POST \
  -H "Authorization: Bearer ${installation_token}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${OWNER}/${REPO}/actions/runners/registration-token" \
  | jq -r .token
```

## Step 5 — box: run-slot.sh

`/opt/gha-runner/run-slot.sh` (root 0750). One cycle per invocation.

```bash
#!/usr/bin/env bash
# One ephemeral GitHub Actions runner cycle for instance "<repo>-<slot>".
# systemd restarts us, so each slot is a continuously-online idle worker that
# runs exactly one job per registration (ARC-pod parity, incl. per-slot dind).
set -euo pipefail

INSTANCE="${1:?instance, e.g. lawncare-saas-1}"
REPO="${INSTANCE%-*}"
OWNER="andrewthetechie"
RUNNER_IMAGE="ghcr.io/falcondev-oss/actions-runner:2.338.2"
DIND_IMAGE="docker:dind"
BUILDKIT_IMAGE="moby/buildkit@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8"  # v0.32.2, same digest as ARC
HOST_LAN_IP="10.10.0.31"
REGISTRY_LOCAL_HOST="registry-local.registry-cache.svc.cluster.local"
RUNNER_NAME="box31-${INSTANCE}"
# Repos whose CI uses docker/buildx; space-game is rust-only.
DOCKER_REPOS=" lawncare-saas womens-fantasy-sports writers-app "

STATE="/var/lib/gha-runner/${INSTANCE}"
WORK="${STATE}/work"
DIND_RUN="${STATE}/dind-run"
DIND_NAME="gha-dind-${INSTANCE}"
BUILDKIT_NAME="gha-buildkit-${INSTANCE}"
RUNNER_CT="gha-runner-${INSTANCE}"

cleanup() {
  docker rm -f "$RUNNER_CT" "$BUILDKIT_NAME" "$DIND_NAME" >/dev/null 2>&1 || true
  rm -rf "$STATE"
}
# clear any leftovers from a SIGKILLed previous cycle, then start fresh
cleanup
trap cleanup EXIT
mkdir -p "$WORK" "$DIND_RUN"

TOKEN="$(/opt/gha-runner/mint-token.sh "$REPO")"

if [[ "$DOCKER_REPOS" == *" $REPO "* ]]; then
  # Per-slot dind: isolated daemon + netns ⇒ no host-port collisions between
  # concurrent jobs (compose files publish :80/:443/:5432/...).
  docker run -d --name "$DIND_NAME" --privileged \
    -v "$WORK:/home/runner/_work" \
    -v "$DIND_RUN:/var/run" \
    -v /etc/gha-runner/dind-daemon.json:/etc/docker/daemon.json:ro \
    --add-host "${REGISTRY_LOCAL_HOST}:${HOST_LAN_IP}" \
    "$DIND_IMAGE" dockerd --host=unix:///var/run/docker.sock --group=123 >/dev/null

  # Wait for dockerd (mirrors ARC's RUNNER_WAIT_FOR_DOCKER_IN_SECONDS).
  for _ in $(seq 1 60); do
    docker exec "$DIND_NAME" docker version >/dev/null 2>&1 && break
    sleep 2
  done

  # Per-slot buildkitd sharing dind's netns (BUILDKIT_HOST=tcp://127.0.0.1:1234).
  docker run -d --name "$BUILDKIT_NAME" --privileged \
    --network "container:${DIND_NAME}" \
    -v /etc/gha-runner/buildkitd.toml:/etc/buildkit/buildkitd.toml:ro \
    "$BUILDKIT_IMAGE" --addr tcp://127.0.0.1:1234 --config /etc/buildkit/buildkitd.toml >/dev/null

  NET_ARGS=(--network "container:${DIND_NAME}" --group-add 123
            -v "$DIND_RUN:/var/run" -v "$WORK:/home/runner/_work")
  ENV_ARGS=(-e DOCKER_HOST=unix:///var/run/docker.sock
            -e BUILDKIT_HOST=tcp://127.0.0.1:1234)
else
  NET_ARGS=(--network host -v "$WORK:/home/runner/_work")
  ENV_ARGS=()
fi

# Ephemeral runner: registers (label = repo name, same pool as the ARC scale
# set), idles until it takes ONE job, then exits. Token expires after
# registration, which is fine — runners hold their own session credentials.
docker run --rm --name "$RUNNER_CT" \
  "${NET_ARGS[@]}" "${ENV_ARGS[@]}" \
  -e RUNNER_TOKEN="$TOKEN" \
  -e GITHUB_URL="https://github.com/${OWNER}/${REPO}" \
  -e RUNNER_NAME="$RUNNER_NAME" \
  -e LABELS="$REPO" \
  -e CUSTOM_ACTIONS_RESULTS_URL="https://actions-cache.herrington.services/" \
  --entrypoint /bin/bash \
  "$RUNNER_IMAGE" -c './config.sh --unattended --url "$GITHUB_URL" \
      --token "$RUNNER_TOKEN" --name "$RUNNER_NAME" --labels "$LABELS" \
      --ephemeral --work /home/runner/_work && exec ./run.sh'
```

Note: `config.sh`/`run.sh` run as image user `runner` (uid 1000); `--work` writes
into `$WORK` on the host — created by root above, chown it if the runner errors
with EACCES (`chown -R 1000:1000 "$WORK"` before the runner starts is a safe
addition).

## Step 6 — box: systemd units

`/etc/systemd/system/gha-registry-local-forward.service`:

```ini
[Unit]
Description=Forward registry-local (cluster NodePort 30500) to 10.10.0.31:5000 for runner dind
After=network-online.target
Wants=network-online.target

[Service]
# amos = 10.10.0.20; any node IP works. If that node dies, point at another.
ExecStart=/usr/bin/socat TCP4-LISTEN:5000,bind=10.10.0.31,fork,reuseaddr TCP4:10.10.0.20:30500
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/gha-runner@.service`:

```ini
[Unit]
Description=Ephemeral GitHub Actions runner slot %i
After=network-online.target docker.service gha-registry-local-forward.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=exec
ExecStart=/opt/gha-runner/run-slot.sh %i
Restart=always
RestartSec=10
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
```

## Step 7 — start everything

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gha-registry-local-forward.service
for repo in lawncare-saas space-game womens-fantasy-sports writers-app; do
  for slot in 1 2; do
    sudo systemctl enable --now "gha-runner@${repo}-${slot}.service"
  done
done
```

## Verification (all must pass before calling it done)

1. `systemctl is-active gha-registry-local-forward.service` and
   `curl -s http://10.10.0.31:5000/v2/` → `{}`.
2. Per repo (×4): GitHub → Settings → Actions → Runners shows **2 `box31-*`
   runners, Idle**. `journalctl -u gha-runner@lawncare-saas-1 -n 50` shows
   "Connected to GitHub".
3. registry-local reachable from inside a slot's dind netns:
   `sudo docker exec gha-dind-lawncare-saas-1 curl -s http://registry-local.registry-cache.svc.cluster.local:5000/v2/`
   → `{}` (proves add-host → socat → NodePort chain).
4. Trigger one real workflow per repo (workflow_dispatch or PR) and confirm the
   job lands on a `box31-*` runner and passes, specifically:
   - lawncare-saas: a docker-main build — `cache-to`/`cache-from` registry-local
     refs resolve, buildx reaches buildkitd via `tcp://127.0.0.1:1234`.
   - womens-fantasy-sports: playwright workflow — image push to registry-local
     (prepare) and pull-back (test) both succeed.
   - writers-app: docker build job.
   - space-game: cargo build/test job (no docker involved).
5. Failure-mode test: `sudo systemctl stop 'gha-runner@*'`, push a trivial commit
   → the job must still run on an ARC pod (box absent ≠ blocked). Start units
   again and confirm slots re-register.

## Operations

- **Runner version pin**: `2.338.2` must move in lockstep with the ARC values
  files (GitHub deprecates old runner versions; a too-old image shows up as
  config.sh failures in `journalctl -u gha-runner@*`).
- **App key rotation**: if `arc-github-app` sealed secret is rotated, re-copy the
  .pem to the box (Step 2).
- **Tuning concurrency**: slots are independent —
  `sudo systemctl disable --now gha-runner@womens-fantasy-sports-2` etc. The user
  has accepted that 8 concurrent jobs oversubscribe the 8 threads (repos rarely
  all run at once); worst case individual jobs run slower, never blocked. Dial
  slots back only if it becomes a real problem.
- **Node outage**: if amos (10.10.0.20) goes down, registry-local becomes
  unreachable from the box — edit the socat target in the forwarder unit to any
  live node and restart it. (Optional hardening: replace socat with haproxy and
  list all six nodes as backends.)
- **Disk**: per-slot state is wiped every cycle; host only holds the 3 static
  images. Optional weekly safety net: a systemd timer running
  `docker system prune -f --filter until=168h`.
- **Stale offline runners**: after a hard power loss, dead `box31-*`
  registrations linger Offline in the GitHub UI; they're harmless. Clean
  manually from a machine with `gh` when they annoy you.
- Unattended-upgrades may restart docker occasionally; affected slots fail once
  and systemd restarts them.

## Rollback

Box: `sudo systemctl disable --now 'gha-runner@*' gha-registry-local-forward.service`,
remove `/opt/gha-runner`, `/etc/gha-runner`, `/var/lib/gha-runner`, and the two
unit files. Jobs revert to ARC-only immediately (labels unchanged).
Cluster: `git revert` the NodePort manifest.

## Phase 2 (optional, later): use the cluster registry mirrors

The pull-through caches (`registry-dockerhub`, `registry-ghcr`, `registry-mcr`)
are ClusterIP-only. To spare the box's internet bandwidth on every job (per-slot
dind pulls full base images each job): NodePort each (30501–30503), socat-forward
them on `10.10.0.31:5001-5003`, then add to `dind-daemon.json`:
`"registry-mirrors": ["http://10.10.0.31:5001"]`,
`"insecure-registries": ["10.10.0.31:5001", ...]`, and matching
`[registry."docker.io"] mirrors = ["10.10.0.31:5001"]` (+ `http = true` sections)
in `buildkitd.toml`. Mirrors are config-only on the box (no workflow changes
needed, unlike registry-local's hardcoded hostname).

---

## Deployment notes (2026-11-22 rollout, everything verified working)

All steps ran as planned; four fixes were needed mid-rollout. Real jobs were
forced onto box runners and passed end-to-end for all four repos (writers-app
`docker build`; space-game rust path + actions/cache via the LAN cache server;
lawncare-saas and womens-fantasy-sports the full production recipe —
`setup-buildx-action` remote driver → per-slot buildkitd → registry-local
cache roundtrip via `build-push-action`, plus a playwright-style image
push-then-pull through registry-local). Failure-mode test passed: slots stopped
⇒ all `box31-*` offline, ARC scale sets unaffected; restarted ⇒ self-cleanup
swept stale registrations, jobs landed on box runners again.

Deviations from the plan above (the `standalone-box/` scripts already include
all of these — trust them over the inline listings):

1. **Runner uid is 1001, not 1000.** The falcondev image's `runner` user has
   uid 1001; the first jobs died on `_work/_tool: permission denied` because
   `chown 1000` matched the host user instead. `run-slot.sh` now chowns slot
   state to 1001:1001 and chmods `_work` 0777 (shared with root-run job
   containers via dind bind mounts; state is wiped every cycle).
2. **Per-cycle unique runner names.** Static `box31-<instance>` names collide
   forever after any unclean exit ("A runner exists with the same name"). Names
   are now `box31-<instance>-<epoch-seconds>`, and `run-slot.sh` deletes stale
   offline `box31-<instance>-*` registrations before registering and again after
   the cycle, via an installation token
   (`/opt/gha-runner/installation-token.sh`, minted from the same App; the App
   has Administration: read-write).
3. **Slots also register a `box31` label** (in addition to the repo label). It
   changes no routing (a job's `runs-on` must be a *subset* of a runner's
   labels, and `runs-on: <repo>` still matches both pools) and makes jobs
   testable in isolation: dispatch any workflow whose `runs-on` accepts an input
   with `runner=box31` to force it onto the box (or `runner=<repo>` to let it
   race ARC normally).
4. **buildkitd readiness wait** added after starting the sidecar (observed race
   on a loaded box: job hit buildkitd's port before it listened; a later run of
   the same code raced once more before the wait shipped).
5. Misc: `docker info` has no `ServerName` field (use `{{.Name}}`); gh has no
   `gh pr create -q`.

Useful commands:

```bash
# status / logs
systemctl list-units 'gha-runner@*' --no-pager
journalctl -u gha-runner@lawncare-saas-1 -f
# one job landed on the box?
gh api repos/andrewthetechie/<repo>/actions/runs/<id>/jobs --jq '.jobs[0].runner_name'
# force a box run (workflow must take a runner input, or temporarily edit runs-on)
gh workflow run "<workflow>" -R andrewthetechie/<repo> -f runner=box31
# registry-local from the box
ssh andrew@10.10.0.31 curl -s http://10.10.0.31:5000/v2/
```
