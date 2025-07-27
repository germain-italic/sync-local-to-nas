#!/bin/bash

# NAS synchronization script
# Synchronizes source folders to destination NAS

set -e

# Load configuration from .env
if [ ! -f .env ]; then
    echo "Error: .env file does not exist. Create it from .env.example"
    exit 1
fi

# Load environment variables
set -a
source .env
set +a

# Validate required variables
if [ -z "$NAS_HOST" ] || [ -z "$DESTINATION" ]; then
    echo "Error: Missing variables in .env (NAS_HOST, DESTINATION)"
    exit 1
fi

# Get all SOURCE_* folders in numerical order
SOURCE_ARRAY=()
for var in $(env | grep '^SOURCE_[0-9]' | sort -V | cut -d= -f1); do
    SOURCE_ARRAY+=("${!var}")
done

# Check that at least one source folder is defined
if [ ${#SOURCE_ARRAY[@]} -eq 0 ]; then
    echo "Error: No source folder defined (use SOURCE_1, SOURCE_2, etc.)"
    exit 1
fi

# Configuration
FULL_DESTINATION="$NAS_HOST:$DESTINATION"
LOG_FILE="/tmp/sync_nas.log"
MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}

# Check source folders exist
for source in "${SOURCE_ARRAY[@]}"; do
    if [ ! -d "$source" ]; then
        echo "Error: Source folder $source does not exist"
        exit 1
    fi
done

echo "$(date): Starting synchronization" | tee -a "$LOG_FILE"

# Base rsync options
BASE_OPTS="-avS --partial --progress --stats --human-readable --itemize-changes --log-file=$LOG_FILE"

# Add checksum if enabled
if [ "$USE_CHECKSUM" = "true" ]; then
    echo "Checksum mode enabled (slower but more reliable for torrents)"
    CHECKSUM_OPT="-c"
else
    echo "Fast mode enabled (based on date/size)"
    CHECKSUM_OPT=""
fi

SSH_OPTS="ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ConnectTimeout=30"
RSYNC_OPTS="$BASE_OPTS $CHECKSUM_OPT -e $RSYNC_EXTRA_OPTS"

# Retry function with exponential backoff
sync_with_retry() {
    local source="$1"
    local destination="$2"
    local exclude_opts="$3"
    local attempt=1
    
    while [ $attempt -le $MAX_ATTEMPTS ]; do
        echo "Attempt $attempt/$MAX_ATTEMPTS for $source"
        if rsync $RSYNC_OPTS "$SSH_OPTS" $exclude_opts "$source" "$destination"; then
            echo "Synchronization successful for $source"
            return 0
        else
            echo "Synchronization failed (attempt $attempt/$MAX_ATTEMPTS)"
            if [ $attempt -lt $MAX_ATTEMPTS ]; then
                local wait_time=$((attempt * 30))
                echo "Waiting ${wait_time}s before next attempt..."
                sleep $wait_time
            fi
            attempt=$((attempt + 1))
        fi
    done
    
    echo "ERROR: Synchronization failed after $MAX_ATTEMPTS attempts for $source"
    return 1
}

# Synchronize all source folders
for i in "${!SOURCE_ARRAY[@]}"; do
    source="${SOURCE_ARRAY[$i]}"
    echo "Synchronizing $source to $FULL_DESTINATION"
    sync_with_retry "$source" "$FULL_DESTINATION" ""
done

echo "$(date): Synchronization completed" | tee -a "$LOG_FILE"
echo "Log available at: $LOG_FILE"
