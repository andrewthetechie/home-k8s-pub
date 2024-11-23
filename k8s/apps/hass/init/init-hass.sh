#!/bin/sh
# Convert declarative Home Assistant configmaps into files copied into the /config PVC
SCRIPT_PATH="${SCRIPT_PATH:-/scripts}"
set -e
# Ensure /config directory exists
mkdir -p /config

# Run the git download script
/bin/sh /scripts/run-git-download.sh || : # Ignore errors

# CONFIG_SUBDIRS is a list of configmaps that are mounted to / that need to be copied into /config/DIRNAME
# I.e. if CONFIG_SUBDIRS is foo,bar then there will be a /config/foo and a /config/bar 
# with the yaml files from /foo and /bar copied into it
# Check if CONFIG_SUBDIRS is set
if [ -n "$CONFIG_SUBDIRS" ]; then
  # Temporarily change IFS to comma and iterate over each item in CONFIG_SUBDIRS
  old_IFS="$IFS"
  IFS=','
  for subdir in $CONFIG_SUBDIRS; do
    # Create the target subdirectory under /config
    mkdir -p "/config/$subdir"
    
    # Copy .yaml, js, and css files from the source subdirectory to the target subdirectory
    if [ -d "/$subdir" ]; then
      cp /"$subdir"/*.yaml "/config/$subdir/" 2>/dev/null || true
      cp /"$subdir"/*.js "/config/$subdir/" 2>/dev/null || true
      cp /"$subdir"/*.css "/config/$subdir/" 2>/dev/null || true
    fi
  done
  IFS="$old_IFS"  # Restore original IFS
fi

# the config-map of split configs is mounted to /configs
# Copy all .yaml files from /configs to /config
if [ -d "/configs" ]; then
  cp /configs/*.yaml /config/ 2>/dev/null || true
fi

# secrets are mounted to /secrets
# Copy all .yaml files from /secrets to /config
if [ -d "/secrets" ]; then
  cp /secrets/*.yaml /config/ 2>/dev/null || true
fi
