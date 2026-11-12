#!/usr/bin/env bash
#
# install-exporters.sh — install the host-level Prometheus exporters on the four
# inference boxes, idempotently, from the Mac over ssh.
#
#   node_exporter       v1.12.1  all four hosts, :9100, with --collector.drm and
#                                --collector.hwmon (drm is off by default upstream)
#   nvidia_gpu_exporter v1.18.0  both sparks, :9835 (the packaged default)
#
# It opens 9100/tcp and 9835/tcp to the LAN in whichever of firewalld or ufw is
# active, and changes nothing else. It never restarts, reconfigures or reloads an
# inference engine.
#
#   ./install-exporters.sh --dry-run    print, per host, every command it would run
#   ./install-exporters.sh              do it
#   ./install-exporters.sh --hosts 10.10.0.29,10.10.0.30   only these hosts
#
# --dry-run still connects, but only to look: it reads file paths, runs
# `node_exporter --version`, `dpkg-query -W`, `cat` of the unit file and
# `firewall-cmd --query-rich-rule` / `ufw status`, then prints the commands each
# host needs. It writes nothing.
#
# Pinned versions, and why, are in docs/plans/2026-11-12-inference-metrics.md
# under "Pinned versions".

set -euo pipefail

NODE_EXPORTER_VERSION="1.12.1"
NVIDIA_GPU_EXPORTER_VERSION="1.18.0"
LAN_CIDR="10.10.0.0/24"
SSH_USER="${SSH_USER:-andrew}"

# role:host — the boxes and their engines, from the plan's "Boxes" table.
HOSTS=(
  "strix:10.10.0.29"
  "strix:10.10.0.56"
  "spark:10.10.0.30"
  "spark:10.10.0.55"
)

DRY_RUN=0
ONLY=""

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --hosts) ONLY="${2:?--hosts needs a comma-separated list}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# The program that runs on each host, as root, over ssh. Positional args:
#   $1 plan|apply   $2 role (strix|spark)   $3 node_exporter version
#   $4 nvidia_gpu_exporter version   $5 LAN CIDR
#
# Every change goes through `step`, which prints the exact command in plan mode
# and prints then runs it in apply mode. The checks that decide whether a step is
# needed run in both modes and are read-only.
remote_program() {
  cat <<'REMOTE'
set -eu

mode="$1"
role="$2"
ne_version="$3"
nge_version="$4"
lan_cidr="$5"

changed=""
say()  { printf '  %s\n' "$*"; }
step() {                              # step "<exact command>" shell-function
  if [ "$mode" = plan ]; then
    printf '  would run: %s\n' "$1"
  else
    printf '  run: %s\n' "$1"
  fi
  changed=1
  shift
  [ "$mode" = plan ] && return 0
  "$@"
}

case "$(uname -m)" in
  x86_64|amd64)  ne_arch=amd64 ;;
  aarch64|arm64) ne_arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
say "host $(hostname) ($(uname -m)), role ${role}"

tmp=""
ne_tgz="node_exporter-${ne_version}.linux-${ne_arch}.tar.gz"
ne_url="https://github.com/prometheus/node_exporter/releases/download/v${ne_version}/${ne_tgz}"
ne_sums="https://github.com/prometheus/node_exporter/releases/download/v${ne_version}/sha256sums.txt"

mktmp()         { tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; }
fetch_ne_tgz()  { curl -fsSL -o "$tmp/$ne_tgz" "$ne_url"; }
fetch_ne_sums() { curl -fsSL -o "$tmp/sha256sums.txt" "$ne_sums"; }
verify_ne()     { ( cd "$tmp" && grep " node_exporter-${ne_version}.linux-${ne_arch}\.tar\.gz$" sha256sums.txt | sha256sum -c - ); }
unpack_ne()     { tar -xzf "$tmp/$ne_tgz" -C "$tmp"; }
install_ne()    {
  install -m 0755 "$tmp/node_exporter-${ne_version}.linux-${ne_arch}/node_exporter" /usr/local/bin/node_exporter
  # Fedora runs SELinux enforcing: give the binary its policy label (bin_t) so
  # systemd may exec it. A no-op where SELinux is absent.
  if command -v restorecon >/dev/null 2>&1; then restorecon /usr/local/bin/node_exporter; fi
}
make_ne_user()  { useradd --system --no-create-home --shell /sbin/nologin node_exporter; }

# ---- node_exporter ---------------------------------------------------------
# Fedora 44 ships no node_exporter package and Ubuntu 24.04 only carries 1.7.0,
# so every host gets the same pinned release binary and unit. One flag differs:
# on the sparks (GB10 / Grace) the cpufreq collector hangs forever when the
# exporter runs unprivileged — the whole /metrics call never returns — so it is
# switched off there. Measured on spark-1 2026-11-12: with cpufreq, /metrics
# timed out after 120s as the node_exporter user and answered in 0.2s as root;
# with --no-collector.cpufreq it answers in 0.18s as the node_exporter user.
# Nothing in the dashboards or alerts uses node_cpu_frequency_*.
if [ "$role" = spark ]; then
  ne_extra_flag=" --no-collector.cpufreq"
else
  ne_extra_flag=""
fi
restart_ne=0
if [ -x /usr/local/bin/node_exporter ] &&
   /usr/local/bin/node_exporter --version 2>&1 | grep -q "version ${ne_version} "; then
  say "node_exporter ${ne_version} already installed at /usr/local/bin/node_exporter"
else
  say "node_exporter ${ne_version} missing or different: installing the linux-${ne_arch} release binary"
  step "mktemp -d   # scratch dir for the download" mktmp
  step "curl -fsSL -o \$TMP/${ne_tgz} ${ne_url}" fetch_ne_tgz
  step "curl -fsSL -o \$TMP/sha256sums.txt ${ne_sums}" fetch_ne_sums
  step "grep ' ${ne_tgz}\$' \$TMP/sha256sums.txt | sha256sum -c -" verify_ne
  step "tar -xzf \$TMP/${ne_tgz} -C \$TMP" unpack_ne
  step "install -m 0755 \$TMP/node_exporter-${ne_version}.linux-${ne_arch}/node_exporter /usr/local/bin/node_exporter" install_ne
  restart_ne=1
fi

if id -u node_exporter >/dev/null 2>&1; then
  say "user node_exporter exists"
else
  step "useradd --system --no-create-home --shell /sbin/nologin node_exporter" make_ne_user
  restart_ne=1
fi

unit=/etc/systemd/system/node_exporter.service
desired=$(cat <<UNIT
[Unit]
Description=Prometheus node exporter
Documentation=https://github.com/prometheus/node_exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter --collector.drm --collector.hwmon${ne_extra_flag} --web.listen-address=:9100
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=read-only
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT
)
write_unit()    { printf '%s\n' "$desired" > "$unit"; }
daemon_reload() { systemctl daemon-reload; }
enable_ne()     { systemctl enable node_exporter.service; }
restart_ne_svc() { systemctl restart node_exporter.service; }
start_ne_svc()  { systemctl start node_exporter.service; }
if [ "$(cat "$unit" 2>/dev/null || true)" = "$desired" ]; then
  say "$unit up to date (--collector.drm --collector.hwmon${ne_extra_flag} --web.listen-address=:9100)"
else
  step "write $unit:" write_unit
  if [ "$mode" = plan ]; then
    printf '%s\n' "$desired" | sed 's/^/             | /'
  fi
  restart_ne=1
fi

if [ "$restart_ne" = 1 ]; then
  step "systemctl daemon-reload" daemon_reload
fi
if systemctl is-enabled --quiet node_exporter.service; then
  say "node_exporter.service enabled"
else
  step "systemctl enable node_exporter.service" enable_ne
fi
if [ "$restart_ne" = 1 ]; then
  step "systemctl restart node_exporter.service" restart_ne_svc
elif systemctl is-active --quiet node_exporter.service; then
  say "node_exporter.service active"
else
  step "systemctl start node_exporter.service" start_ne_svc
fi

# ---- nvidia_gpu_exporter (sparks only) -------------------------------------
# The .deb's postinst creates the nvidia_gpu_exporter user, installs
# /usr/bin/nvidia_gpu_exporter and its unit, and enables and starts it.
if [ "$role" = spark ]; then
  case "$(uname -m)" in
    aarch64|arm64) nge_arch=arm64 ;;
    x86_64|amd64)  nge_arch=x86_64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  nge_deb="nvidia-gpu-exporter_${nge_version}_linux_${nge_arch}.deb"   # e.g. nvidia-gpu-exporter_1.18.0_linux_arm64.deb, as checksums.txt lists it
  nge_url="https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/download/v${nge_version}/${nge_deb}"
  nge_sums="https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/download/v${nge_version}/checksums.txt"
  fetch_nge_deb()  { curl -fsSL -o "$tmp_nge/$nge_deb" "$nge_url"; }
  fetch_nge_sums() { curl -fsSL -o "$tmp_nge/checksums.txt" "$nge_sums"; }
  verify_nge()     { ( cd "$tmp_nge" && grep " ${nge_deb}\$" checksums.txt | sha256sum -c - ); }
  install_nge()    { dpkg -i "$tmp_nge/$nge_deb"; }
  restart_nge_svc() { systemctl restart nvidia_gpu_exporter.service; }

  nge_have=$(dpkg-query -W -f='${Version}' nvidia-gpu-exporter 2>/dev/null || true)
  if [ "$nge_have" = "$nge_version" ]; then
    say "nvidia_gpu_exporter ${nge_version} already installed (/usr/bin/nvidia_gpu_exporter, :9835)"
  else
    say "nvidia_gpu_exporter ${nge_version} missing or different: installing ${nge_deb}"
    tmp_nge=""
    mktmp_nge()      { tmp_nge=$(mktemp -d); }
    step "mktemp -d   # scratch dir for the .deb" mktmp_nge
    step "curl -fsSL -o \$TMP/${nge_deb} ${nge_url}" fetch_nge_deb
    step "curl -fsSL -o \$TMP/checksums.txt ${nge_sums}" fetch_nge_sums
    step "grep ' ${nge_deb}\$' \$TMP/checksums.txt | sha256sum -c -" verify_nge
    step "dpkg -i \$TMP/${nge_deb}   # postinst: user nvidia_gpu_exporter, unit, :9835" install_nge
    say "dpkg -i enables and starts nvidia_gpu_exporter.service on :9835"
  fi
  if [ "$nge_have" != "$nge_version" ]; then
    :   # the postinst just did it, or the plan covers it
  elif systemctl is-active --quiet nvidia_gpu_exporter.service; then
    say "nvidia_gpu_exporter.service active on :9835"
  else
    step "systemctl restart nvidia_gpu_exporter.service" restart_nge_svc
  fi
fi

# ---- firewall --------------------------------------------------------------
# Open the exporter ports to the LAN only, in whichever firewall is active.
open_port() {
  port="$1"
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    rule="rule family=\"ipv4\" source address=\"${lan_cidr}\" port protocol=\"tcp\" port=\"${port}\" accept"
    fw_add() { firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null && firewall-cmd --add-rich-rule="$rule" >/dev/null; }
    if firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1; then
      say "firewalld: ${port}/tcp from ${lan_cidr} already allowed"
    else
      step "firewall-cmd --permanent --add-rich-rule='${rule}' && firewall-cmd --add-rich-rule='${rule}'" fw_add
    fi
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw_add() { ufw allow proto tcp from "$lan_cidr" to any port "$port" >/dev/null; }
    if ufw status 2>/dev/null | grep -qE "^${port}/tcp +(ALLOW|LIMIT) +${lan_cidr}( |$)"; then
      say "ufw: ${port}/tcp from ${lan_cidr} already allowed"
    else
      step "ufw allow proto tcp from ${lan_cidr} to any port ${port}" ufw_add
    fi
  else
    say "no active firewalld or ufw: ${port}/tcp needs no rule"
  fi
}

open_port 9100
if [ "$role" = spark ]; then
  open_port 9835
fi

# ---- self-check (apply mode only) -----------------------------------------
if [ "$mode" = plan ]; then
  if [ -n "$changed" ]; then
    printf '  = result: changes needed\n'
  else
    printf '  = result: nothing to change\n'
  fi
  exit 0
fi

sleep 1
if curl -fsS --max-time 5 http://127.0.0.1:9100/metrics 2>/dev/null | grep -q '^node_'; then
  say "http://127.0.0.1:9100/metrics answers with node_ metrics"
else
  echo "node_exporter is not answering on :9100" >&2
  exit 1
fi
if [ "$role" = spark ] &&
   ! curl -fsS --max-time 5 http://127.0.0.1:9835/metrics 2>/dev/null | grep -q '^nvidia_smi_'; then
  echo "nvidia_gpu_exporter is not answering on :9835" >&2
  exit 1
fi
if [ -n "$changed" ]; then
  printf '  = result: changed\n'
else
  printf '  = result: nothing to change\n'
fi
REMOTE
}

run_remote() {
  host="$1"
  role="$2"
  mode="$3"
  # shellcheck disable=SC2029  # the remote shell is meant to expand the arguments
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${host}" \
    "sudo -n /bin/sh -s -- ${mode} ${role} ${NODE_EXPORTER_VERSION} ${NVIDIA_GPU_EXPORTER_VERSION} ${LAN_CIDR}" \
    < <(remote_program)
}

verify_from_here() {
  host="$1"
  role="$2"
  count=$(curl -fsS --max-time 5 "http://${host}:9100/metrics" 2>/dev/null | grep -c '^node_' || true)
  printf '  verify: http://%s:9100/metrics -> %s node_ series\n' "$host" "$count"
  if [ "$role" = strix ]; then
    drm=$(curl -fsS --max-time 5 "http://${host}:9100/metrics" 2>/dev/null |
      grep '^node_drm_gpu_busy_percent' || true)
    printf '  verify: http://%s:9100/metrics -> %s\n' "$host" "${drm:-node_drm_gpu_busy_percent MISSING}"
  fi
  if [ "$role" = spark ]; then
    util=$(curl -fsS --max-time 5 "http://${host}:9835/metrics" 2>/dev/null |
      grep '^nvidia_smi_utilization_gpu_ratio' || true)
    printf '  verify: http://%s:9835/metrics -> %s\n' "$host" "${util:-nvidia_smi_utilization_gpu_ratio MISSING}"
  fi
}

selected() {
  [ -z "$ONLY" ] && return 0
  case ",${ONLY}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

for entry in "${HOSTS[@]}"; do
  role="${entry%%:*}"
  host="${entry##*:}"
  selected "$host" || continue
  printf '\n== %s (%s, %s@%s)\n' "$host" "$role" "$SSH_USER" "$host"
  if [ "$DRY_RUN" = 1 ]; then
    run_remote "$host" "$role" plan
    printf '  verify later from the Mac:\n'
    printf '    curl -s http://%s:9100/metrics | grep -c "^node_"\n' "$host"
    if [ "$role" = strix ]; then
      printf '    curl -s http://%s:9100/metrics | grep node_drm_gpu_busy_percent\n' "$host"
    fi
    if [ "$role" = spark ]; then
      printf '    curl -s http://%s:9835/metrics | grep nvidia_smi_utilization_gpu_ratio\n' "$host"
    fi
  else
    run_remote "$host" "$role" apply
    verify_from_here "$host" "$role"
  fi
done

if [ "$DRY_RUN" = 1 ]; then
  printf '\nDry run: nothing was written on any host.\n'
fi
