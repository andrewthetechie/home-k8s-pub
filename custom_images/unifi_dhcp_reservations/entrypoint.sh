#!/bin/bash

# Set default wait time to 600 seconds if WAIT_SECONDS is not set
WAIT_SECONDS="${WAIT_SECONDS:-600}"

# Validate that WAIT_SECONDS is a positive integer
if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || [ "$WAIT_SECONDS" -le 0 ]; then
  echo "WAIT_SECONDS must be a positive integer. Defaulting to 600 seconds."
  WAIT_SECONDS=600
fi

echo "Loop will run every $WAIT_SECONDS seconds."

# Infinite loop
while true; do
  echo "Starting iteration at $(date)"
  
  python /ip_reservation_google_sheet.py

  echo "Iteration completed. Sleeping for $WAIT_SECONDS seconds."
  sleep "$WAIT_SECONDS"
done
