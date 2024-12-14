#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Validate required environment variables
if [[ -z "$STOP_SERVICES" || -z "$BACKUP_DIRS" || -z "$RESTIC_REPO" ]]; then
  echo "Error: STOP_SERVICES, BACKUP_DIRS, and RESTIC_REPO environment variables must be set."
  exit 1
fi

# Split comma-separated lists into arrays
IFS=',' read -ra SERVICES <<< "$STOP_SERVICES"
IFS=',' read -ra DIRECTORIES <<< "$BACKUP_DIRS"

# Stop each service in the STOP_SERVICES list
for SERVICE in "${SERVICES[@]}"; do
  echo "Stopping service: $SERVICE"
  systemctl stop "$SERVICE"
done

# Backup each directory in the BACKUP_DIRS list
for DIRECTORY in "${DIRECTORIES[@]}"; do
  echo "Backing up directory: $DIRECTORY"
  restic -r "$RESTIC_REPO" backup "$DIRECTORY"
done

# Start each service in the STOP_SERVICES list
for SERVICE in "${SERVICES[@]}"; do
  echo "Starting service: $SERVICE"
  systemctl start "$SERVICE"
done

echo "Backup and service management completed successfully."