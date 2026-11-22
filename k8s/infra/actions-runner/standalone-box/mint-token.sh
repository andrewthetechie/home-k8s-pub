#!/usr/bin/env bash
# Print a short-lived runner registration token for andrewthetechie/<repo>,
# minted via the arc-github-app GitHub App (same app ARC uses). Deployed to
# /opt/gha-runner/mint-token.sh on box31 (10.10.0.31) by
# ../STANDALONE-RUNNER-BOX.md — see that file for context and operations.
set -euo pipefail
REPO="${1:?repo name}"
OWNER="andrewthetechie"

installation_token=$(/opt/gha-runner/installation-token.sh)

curl -sfS -X POST \
  -H "Authorization: Bearer ${installation_token}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${OWNER}/${REPO}/actions/runners/registration-token" \
  | jq -r .token
