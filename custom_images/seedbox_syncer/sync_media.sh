#!/bin/bash
# syncs media from the seedbox to the nas. Runs in tmux
# Uses a ssh master connection to minimize load

# Set the following variables in the ENV to run the script
# REMOTE_USER=""
# REMOTE_HOST=""
# REMOTE_DIR=""
# LOCAL_DIR=""

set -euo pipefail

# Ensure required env vars are set and non-empty
: "${REMOTE_USER:?Environment variable REMOTE_USER must be set and non-empty}"
: "${REMOTE_HOST:?Environment variable REMOTE_HOST must be set and non-empty}"
: "${REMOTE_DIR:?Environment variable REMOTE_DIR must be set and non-empty}"
: "${LOCAL_DIR:?Environment variable LOCAL_DIR must be set and non-empty}"

OWNER_USER="${OWNER_USER:-root}"
OWNER_GROUP="${OWNER_GROUP:-root}"
DAY_BWLIMIT="${DAY_BWLIMIT:-30m}"
NIGHT_BWLIMIT="${NIGHT_BWLIMIT:-50m}"
SSH_KEY_PATH="${SSH_KEY_PATH:-~/.ssh/id_rsa}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-10}"
ISP_DOWN_SLEEP_INTERVAL="${ISP_DOWN_SLEEP_INTERVAL:-60}"

# Start the SSH master connection in the background
ssh -M -S /tmp/ssh_mux_%h_%p_%r -fnN "$REMOTE_USER"@"$REMOTE_HOST"

while true; do
    # Check if there are any files on the remote before running rsync
    # This is a 'lightweight' check over the existing SSH mux
    echo 'Checking ISP'
    ISP=$(/check_isp.sh)
    echo "ISP: $ISP"
    if [[ $ISP == "Offline" ]]; then
        echo "ISP is offline, skipping sync for $ISP_DOWN_SLEEP_INTERVAL seconds"
        sleep "$ISP_DOWN_SLEEP_INTERVAL"
        continue
    fi

    if [[ $ISP == "WAN2" ]]; then
        echo "WAN2 is active, skipping sync for $ISP_DOWN_SLEEP_INTERVAL seconds"
        sleep "$ISP_DOWN_SLEEP_INTERVAL"
        continue
    fi

    echo "checking for remote files"
    if ssh -i "${SSH_KEY_PATH}" -S /tmp/ssh_mux_%h_%p_%r "$REMOTE_USER"@"$REMOTE_HOST" "ls -A $REMOTE_DIR" | grep -q .; then
        # Determine bandwidth limit based on time
        HOUR=$(date +%H)
        if [[ $HOUR -ge 0 && $HOUR -lt 6 ]]; then
            BWLIMIT=$NIGHT_BWLIMIT
        else
            BWLIMIT=$DAY_BWLIMIT
        fi
        echo "$(date): Starting rsync with bwlimit=$BWLIMIT..."
        # --remove-source-files ensures the remote file is deleted 
        # ONLY after a successful transfer
        rsync -aPvz --progress --remove-source-files --bwlimit="$BWLIMIT" \
            -e "ssh -i ${SSH_KEY_PATH} -S /tmp/ssh_mux_%h_%p_%r" \
            "$REMOTE_USER"@"$REMOTE_HOST":"$REMOTE_DIR" "$LOCAL_DIR"
            
        # cleanup empty dirs and remake the remotedir if it gets deleted
        ssh -i "${SSH_KEY_PATH}" -S /tmp/ssh_mux_%h_%p_%r "$REMOTE_USER"@"$REMOTE_HOST" "find $REMOTE_DIR -type d -empty -delete"
        ssh -i "${SSH_KEY_PATH}" -S /tmp/ssh_mux_%h_%p_%r "$REMOTE_USER"@"$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

        # Change ownership of synced files
        chown -R "${OWNER_USER}:${OWNER_GROUP}" "$LOCAL_DIR"

        echo "$(date): Sync complete."
    fi
    
    # Very short sleep (e.g., 10 seconds)
    # Because of the Multiplexing, this 'check' is nearly instant
    sleep "$SLEEP_INTERVAL"
done