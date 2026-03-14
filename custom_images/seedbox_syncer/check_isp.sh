#!/usr/bin/env bash
set -euo pipefail

: "${UDM_IP:?UDM_IP not set}"
: "${UDM_USERNAME:?UDM_USERNAME not set}"
: "${UDM_PASSWORD:?UDM_PASSWORD not set}"

# Minimum availability (0-100) to consider a WAN "active". Avoids flapping on noise.
AVAIL_THRESHOLD="${AVAIL_THRESHOLD:-1.0}"

COOKIE=$(mktemp)
trap 'rm -f "$COOKIE"' EXIT

# Login
if ! curl -sk --max-time 3 \
  -X POST "https://${UDM_IP}/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${UDM_USERNAME}\",\"password\":\"${UDM_PASSWORD}\"}" \
  -c "$COOKIE" >/dev/null
then
  echo Offline
  exit 0
fi

DATA=$(curl -sk --max-time 3 \
  "https://${UDM_IP}/proxy/network/api/s/default/stat/health" \
  -b "$COOKIE")

# Parse health: WAN has no top-level .availability when down (only monitors); WAN2 has .availability when up.
# Derive each WAN from .availability or max of monitors/alerting_monitors. Use (obj // {}) so missing WAN/WAN2 is safe.
RESULT=$(echo "$DATA" | jq -r --arg thresh "$AVAIL_THRESHOLD" '
  .data[] | select(.subsystem == "wan") | .uptime_stats as $stats |
  (($stats.WAN // {}) | .availability // (([.alerting_monitors[]?.availability, .monitors[]?.availability] | map(select(. != null)) | if length > 0 then max else 0 end) // 0)) as $wan1 |
  (($stats.WAN2 // {}) | .availability // (([.alerting_monitors[]?.availability, .monitors[]?.availability] | map(select(. != null)) | if length > 0 then max else 0 end) // 0)) as $wan2 |
  if ($wan2 | tonumber) > ($thresh | tonumber) and ($wan1 | tonumber) <= ($thresh | tonumber) then "WAN2"
  elif ($wan1 | tonumber) > ($thresh | tonumber) then "WAN1"
  else "Offline"
  end
')

# Handle missing/empty JSON or API error
if [[ -z "$RESULT" || "$RESULT" == "null" ]]; then
  echo Offline
  exit 0
fi

echo "$RESULT"