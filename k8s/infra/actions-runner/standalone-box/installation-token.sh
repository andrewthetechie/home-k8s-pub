#!/usr/bin/env bash
# Print a GitHub App installation access token (expires in 1h; GitHub reuses a
# token minted within its first 30s). Same arc-github-app GitHub App ARC uses.
# Deployed to /opt/gha-runner/installation-token.sh on box31 (10.10.0.31) by
# ../STANDALONE-RUNNER-BOX.md.
set -euo pipefail
APP_ID="4125846"
INSTALLATION_ID="142156219"
KEY_FILE="/etc/gha-runner/arc-github-app.pem"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+540))" "$APP_ID" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$KEY_FILE" | b64url)

curl -sfS -X POST \
  -H "Authorization: Bearer ${header}.${payload}.${signature}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
  | jq -r .token
