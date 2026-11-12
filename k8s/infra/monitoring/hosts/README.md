# Host exporters for the inference boxes

`install-exporters.sh` puts the two host-level Prometheus exporters on the four
inference boxes and opens their ports to the LAN. It is the only thing in this
stack that touches a box; everything else is in `../`.

Plan: `docs/plans/2026-11-12-inference-metrics.md`, task 2 (D14).

## Run it

From the Mac, in this directory:

```bash
./install-exporters.sh --dry-run    # print every command, per host; writes nothing
./install-exporters.sh              # do it
```

`--dry-run` connects and *looks* (file paths, `node_exporter --version`,
`dpkg-query -W`, `cat` of the unit, `firewall-cmd --query-rich-rule`,
`ufw status`), then prints the commands each host needs. It does not write,
install or restart anything, and it does not send inference requests.

The run itself needs passwordless sudo on the boxes (it has it as of
2026-11-12) and reachability to `github.com` for the release downloads, which is
verified by the sha256 check before anything is installed.

## What it installs

| Host | `node` label | node_exporter | nvidia_gpu_exporter |
|---|---|---|---|
| `10.10.0.29` (amd-inf-1) | `strix1` | v1.12.1 release binary, `:9100` | — |
| `10.10.0.56` (strix2) | `strix2` | v1.12.1 release binary, `:9100` | — |
| `10.10.0.30` (spark-1) | `spark-1` | v1.12.1 release binary, `:9100` | v1.18.0 `.deb`, `:9835` |
| `10.10.0.55` (spark2) | `spark2` | v1.12.1 release binary, `:9100` | v1.18.0 `.deb`, `:9835` |

- `node_exporter`: `/usr/local/bin/node_exporter`, unit
  `/etc/systemd/system/node_exporter.service`, user `node_exporter`, flags
  `--collector.drm --collector.hwmon --web.listen-address=:9100`. `drm` is off
  by default upstream and gives `node_drm_gpu_busy_percent` on the strix
  boxes; `hwmon` gives `node_hwmon_power_average_watt` (the APU PPT reading) and
  `node_hwmon_temp_celsius` (`edge`). Their `chip` label is the PCI path, not
  the driver name (`0000:00:08_1_0000:c3:00_0`), so anything that selects hwmon
  sensors has to join `node_hwmon_chip_names{chip_name="amdgpu"}`.
- On the two sparks the unit adds `--no-collector.cpufreq`, and only there. On
  GB10 the cpufreq collector hangs forever when the exporter runs unprivileged:
  `/metrics` never returns (measured 2026-11-12 on spark-1 — 120 s timeout as
  the `node_exporter` user, 0.2 s as root, 0.18 s with the collector off).
  Nothing in the dashboards or alerts reads `node_cpu_frequency_*`. The strix
  boxes keep the collector.
- SELinux on Fedora: the installer runs `restorecon` on the binary so systemd
  may exec it from `/usr/local/bin` (`bin_t`).
- `nvidia_gpu_exporter`: the project's `.deb`, which installs
  `/usr/bin/nvidia_gpu_exporter`, its own systemd unit and its `nvidia_gpu_exporter`
  user, and listens on `:9835`.
- Firewall: `9100/tcp` on all four, `9835/tcp` on the sparks, allowed from
  `10.10.0.0/24` only — a firewalld rich rule on the strix boxes, `ufw allow`
  on the sparks. Nothing else in either firewall is touched.

Two documented deviations from the plan's task-2 wording, both in the report:

- Every host gets the same pinned v1.12.1 release binary. Fedora 44 has no
  `node_exporter` package, and Ubuntu 24.04 only offers `1.7.0-1ubuntu0.3+esm2`,
  which would leave the four boxes on two versions and an unpinned one.
- `nvidia_gpu_exporter` comes from its `.deb` rather than a bare binary, because
  the package is what creates the user and the unit.

## Checks (the plan's task-2 check)

After the real run, from the Mac:

```bash
for h in 10.10.0.29 10.10.0.56 10.10.0.30 10.10.0.55; do
  printf '%s node_ series: ' "$h"; curl -s "http://$h:9100/metrics" | grep -c '^node_'
done

# both strix boxes: the GPU busy gauge from the drm collector
for h in 10.10.0.29 10.10.0.56; do
  printf '%s: ' "$h"; curl -s "http://$h:9100/metrics" | grep '^node_drm_gpu_busy_percent'
done

# both sparks: the GPU utilisation ratio from nvidia_gpu_exporter
for h in 10.10.0.30 10.10.0.55; do
  printf '%s: ' "$h"; curl -s "http://$h:9835/metrics" | grep '^nvidia_smi_utilization_gpu_ratio'
done

# the strix power and temperature sources the energy panel and the GPU-hot alert use
# (the chip label is a PCI path: find amdgpu's, then its power and temperature)
for h in 10.10.0.29 10.10.0.56; do
  m=$(curl -s "http://$h:9100/metrics")
  chip=$(printf '%s\n' "$m" | sed -n 's/^node_hwmon_chip_names{chip="\([^"]*\)",chip_name="amdgpu"}.*/\1/p')
  printf '%s amdgpu chip=%s\n' "$h" "${chip:-MISSING}"
  printf '%s\n' "$m" | grep -E "^node_hwmon_(power_average_watt|temp_celsius)\{chip=\"$chip\""
done
```

Then run `./install-exporters.sh` a second time. Every host must end with
`= result: nothing to change`: the version check, the `systemctl is-enabled`
check and the firewall query all short-circuit, so no installer and no
`firewall-cmd` write runs.

## If it goes wrong

The installers are additive and reversible without touching an engine:

```bash
# per host
systemctl disable --now node_exporter.service
rm -f /etc/systemd/system/node_exporter.service /usr/local/bin/node_exporter
userdel node_exporter
systemctl daemon-reload
# sparks only
apt-get purge -y nvidia-gpu-exporter
```

and remove the one rich rule / `ufw` rule for the port.
