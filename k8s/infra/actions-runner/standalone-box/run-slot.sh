#!/usr/bin/env bash
# One ephemeral GitHub Actions runner cycle for instance "<repo>-<slot>" on
# box31 (10.10.0.31). systemd restarts us, so each slot is a continuously-online
# idle worker that runs exactly one job per registration (ARC-pod parity, incl.
# per-slot dind). Deployed to /opt/gha-runner/run-slot.sh — see
# ../STANDALONE-RUNNER-BOX.md for context and operations.
set -euo pipefail

INSTANCE="${1:?instance, e.g. lawncare-saas-1}"
REPO="${INSTANCE%-*}"
OWNER="andrewthetechie"
RUNNER_IMAGE="ghcr.io/falcondev-oss/actions-runner:2.338.2"
DIND_IMAGE="docker:dind"
BUILDKIT_IMAGE="moby/buildkit@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8"  # v0.32.2, same digest as ARC
HOST_LAN_IP="10.10.0.31"
REGISTRY_LOCAL_HOST="registry-local.registry-cache.svc.cluster.local"
# Unique per cycle: an unclean exit (SIGKILL, reboot) leaves the ephemeral
# runner registered, and a static name would then collide forever with the
# next registration ("A runner exists with the same name").
RUNNER_NAME="box31-${INSTANCE}-$(date +%s)"
# Prefix matching this slot's previous box31 registrations (any cycle ts).
NAME_PREFIX="box31-${INSTANCE}-"
# Repos whose CI uses docker/buildx; space-game is rust-only.
DOCKER_REPOS=" lawncare-saas womens-fantasy-sports writers-app "
# Box-unique label in addition to the repo label: lets tests force jobs onto
# this box (a job's runs-on label list must be a SUBSET of the runner's). The
# repo label keeps normal production routing identical to the ARC scale set.
BOX_LABEL=box31

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
# config.sh/run.sh run as image user "runner" — uid 1001 in this image, NOT the
# host's uid of the same name (uid 1000). _work is additionally bind-mounted
# into dind and into job containers that may run as root, so it is 0777;
# everything else is owned by the runner uid.
chown -R 1001:1001 "$STATE"
chmod 0777 "$WORK"

INSTALLATION_TOKEN="$(/opt/gha-runner/installation-token.sh)"
TOKEN="$(/opt/gha-runner/mint-token.sh "$REPO")"

# Delete stale box31 registrations left behind by unclean exits of this slot
# (an ephemeral runner removed cleanly removes itself). A still-ONLINE runner
# cannot be deleted (GitHub 400), which protects any live sibling; failures
# here are logged, never fatal — registration proceeds regardless.
remove_stale_runners() {
  local ids
  ids=$(curl -sfS -H "Authorization: Bearer ${INSTALLATION_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${OWNER}/${REPO}/actions/runners" \
    | jq -r --arg p "$NAME_PREFIX" \
      '.runners[] | select(.name | startswith($p)) | select(.status != "online") | .id') || return 0
  local id
  for id in $ids; do
    curl -sfS -X DELETE \
      -H "Authorization: Bearer ${INSTALLATION_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${OWNER}/${REPO}/actions/runners/$id" >/dev/null \
      || echo "stale-runner delete failed (id $id)" >&2
  done
}

if [[ "$DOCKER_REPOS" == *" $REPO "* ]]; then
  # Per-slot dind: isolated daemon + netns => no host-port collisions between
  # concurrent jobs (compose files publish :80/:443/:5432/...).
  docker run -d --name "$DIND_NAME" --privileged \
    -v "$WORK:/home/runner/_work" \
    -v "$DIND_RUN:/var/run" \
    -v /etc/gha-runner/dind-daemon.json:/etc/docker/daemon.json:ro \
    --add-host "${REGISTRY_LOCAL_HOST}:${HOST_LAN_IP}" \
    "$DIND_IMAGE" dockerd --host=unix:///var/run/docker.sock --group=123 >/dev/null

  # Wait for dockerd (mirrors ARC's RUNNER_WAIT_FOR_DOCKER_IN_SECONDS).
  ready=0
  for _ in $(seq 1 60); do
    if docker exec "$DIND_NAME" docker version >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
  done
  [[ "$ready" == 1 ]] || { echo "dockerd did not come up" >&2; exit 1; }

  # Per-slot buildkitd sharing dind's netns (BUILDKIT_HOST=tcp://127.0.0.1:1234).
  docker run -d --name "$BUILDKIT_NAME" --privileged \
    --network "container:${DIND_NAME}" \
    -v /etc/gha-runner/buildkitd.toml:/etc/buildkit/buildkitd.toml:ro \
    "$BUILDKIT_IMAGE" --addr tcp://127.0.0.1:1234 --config /etc/buildkit/buildkitd.toml >/dev/null

  # Wait for buildkitd to listen before registering (observed race: job steps
  # hit a still-starting buildkitd on a loaded box).
  bkready=0
  for _ in $(seq 1 30); do
    if docker exec "$DIND_NAME" sh -c "command -v bash >/dev/null 2>&1 || apk add --no-cache bash >/dev/null 2>&1; timeout 2 bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/1234'" >/dev/null 2>&1; then bkready=1; break; fi
    sleep 2
  done
  [[ "$bkready" == 1 ]] || { echo "buildkitd did not come up" >&2; exit 1; }

  NET_ARGS=(--network "container:${DIND_NAME}" --group-add 123
            -v "$DIND_RUN:/var/run" -v "$WORK:/home/runner/_work")
  ENV_ARGS=(-e DOCKER_HOST=unix:///var/run/docker.sock
            -e BUILDKIT_HOST=tcp://127.0.0.1:1234)
else
  NET_ARGS=(--network host -v "$WORK:/home/runner/_work")
  ENV_ARGS=()
fi

remove_stale_runners

# Ephemeral runner: registers (label = repo name, same pool as the ARC scale
# set), idles until it takes ONE job, then exits and de-registers itself. The
# token expires after registration, which is fine — runners hold their own
# session credentials.
docker run --rm --name "$RUNNER_CT" \
  "${NET_ARGS[@]}" "${ENV_ARGS[@]}" \
  -e RUNNER_TOKEN="$TOKEN" \
  -e GITHUB_URL="https://github.com/${OWNER}/${REPO}" \
  -e RUNNER_NAME="$RUNNER_NAME" \
  -e LABELS="$REPO,$BOX_LABEL" \
  -e CUSTOM_ACTIONS_RESULTS_URL="https://actions-cache.herrington.services/" \
  --entrypoint /bin/bash \
  "$RUNNER_IMAGE" -c './config.sh --unattended --url "$GITHUB_URL" \
      --token "$RUNNER_TOKEN" --name "$RUNNER_NAME" --labels "$LABELS" \
      --ephemeral --work /home/runner/_work && exec ./run.sh'

# The ephemeral runner normally de-registers itself on clean exit; delete this
# cycle's registration here too in case it exited some other way (offline
# entries only — a live runner's id is never matched here).
remove_stale_runners
