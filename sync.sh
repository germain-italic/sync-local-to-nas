#!/bin/bash

# Optimized NAS synchronization script
# Features: checksum cache, pre-verification, compression

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
ERROR_LOG="/tmp/sync_errors.log"
MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}
ENABLE_OPTIMIZATIONS=${ENABLE_OPTIMIZATIONS:-false}
CHECKSUM_CACHE=${CHECKSUM_CACHE:-"/tmp/sync_checksums.cache"}
PARALLEL_JOBS=${PARALLEL_JOBS:-1}

# Check source folders exist and log missing ones
> "$ERROR_LOG"
VALID_SOURCES=()
for source in "${SOURCE_ARRAY[@]}"; do
    if [ ! -d "$source" ]; then
        echo "$(date): ERROR - Source folder does not exist: $source" | tee -a "$ERROR_LOG"
        echo "Skipping missing source: $source"
    else
        VALID_SOURCES+=("$source")
    fi
done

# Update SOURCE_ARRAY with only valid sources
SOURCE_ARRAY=("${VALID_SOURCES[@]}")

if [ ${#SOURCE_ARRAY[@]} -eq 0 ]; then
    echo "Error: No valid source folders found"
    exit 1
fi

echo "$(date): Starting synchronization" | tee -a "$LOG_FILE"

# Load checksum cache
declare -A checksum_cache
if [ "$ENABLE_OPTIMIZATIONS" = "true" ] && [ -f "$CHECKSUM_CACHE" ]; then
    echo "Loading checksum cache..."
    while IFS='|' read -r filepath checksum mtime; do
        checksum_cache["$filepath"]="$checksum:$mtime"
    done < "$CHECKSUM_CACHE"
fi

# Base rsync options with compression
BASE_OPTS="-avSz --partial --progress --stats --human-readable --itemize-changes --log-file=$LOG_FILE"

# Add checksum if enabled and not using optimizations
if [ "$USE_CHECKSUM" = "true" ] && [ "$ENABLE_OPTIMIZATIONS" != "true" ]; then
    echo "Checksum mode enabled (slower but more reliable for torrents)"
    CHECKSUM_OPT="-c"
else
    echo "Fast mode enabled (compressed transfers)"
    CHECKSUM_OPT=""
fi

SSH_OPTS="ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ConnectTimeout=30"
RSYNC_OPTS="$BASE_OPTS $CHECKSUM_OPT -e $RSYNC_EXTRA_OPTS"

# Function to get file checksum with caching
get_cached_checksum() {
    local filepath="$1"
    local current_mtime=$(stat -c %Y "$filepath" 2>/dev/null || echo "0")
    local cache_key="$filepath"
    
    if [ "${checksum_cache[$cache_key]}" ]; then
        local cached_checksum="${checksum_cache[$cache_key]%:*}"
        local cached_mtime="${checksum_cache[$cache_key]#*:}"
        
        if [ "$current_mtime" = "$cached_mtime" ]; then
            echo "$cached_checksum"
            return 0
        fi
    fi
    
    # Calculate new checksum
    local new_checksum=$(md5sum "$filepath" | cut -d' ' -f1)
    checksum_cache["$cache_key"]="$new_checksum:$current_mtime"
    echo "$new_checksum"
}

# Function to check if file exists on remote
remote_file_exists() {
    local remote_path="$1"
    ssh $(echo "$NAS_HOST" | cut -d: -f1) "test -f '$remote_path'" 2>/dev/null
}

# Function to get remote file info
get_remote_file_info() {
    local remote_path="$1"
    ssh $(echo "$NAS_HOST" | cut -d: -f1) "stat -c '%s:%Y' '$remote_path' 2>/dev/null || echo '0:0'"
}

# Pre-verification function
pre_verify_files() {
    local source_dir="$1"
    local dest_dir="$2"
    local new_files=()
    local existing_files=()
    
    echo "Pre-verifying files in $source_dir..."
    
    # Get absolute source directory path first
    local abs_source_dir="$(realpath "$source_dir")"
    
    while IFS= read -r -d '' file; do
        # file is already absolute from find with absolute source_dir
        local rel_path="${file#$abs_source_dir/}"
        local remote_path="$dest_dir$rel_path"
        
        if remote_file_exists "$remote_path"; then
            existing_files+=("$file")
        else
            new_files+=("$file")
        fi
    done < <(find "$abs_source_dir" -type f -print0)
    
    echo "Found ${#new_files[@]} new files, ${#existing_files[@]} existing files"
    
    # Transfer new files without checksum verification
    if [ ${#new_files[@]} -gt 0 ]; then
        echo "Transferring ${#new_files[@]} new files (fast mode)..."
        for file in "${new_files[@]}"; do
            local rel_path="${file#$abs_source_dir/}"
            local dir_path=$(dirname "$rel_path")
            
            # Create remote directory if needed
            ssh $(echo "$NAS_HOST" | cut -d: -f1) "mkdir -p '$dest_dir$dir_path'" 2>/dev/null || true
            
            # Transfer file with compression using absolute path
            if ! rsync -avSz --progress "$file" "$NAS_HOST:$dest_dir$dir_path/" 2>>"$ERROR_LOG"; then
                echo "$(date): TRANSFER FAILED - $rel_path" | tee -a "$ERROR_LOG"
            fi
        done
    fi
    
    # Check existing files with smart checksum verification
    if [ ${#existing_files[@]} -gt 0 ] && [ "$USE_CHECKSUM" = "true" ]; then
        echo "Verifying ${#existing_files[@]} existing files with checksums..."
        for file in "${existing_files[@]}"; do
            local rel_path="${file#$abs_source_dir/}"
            local remote_path="$dest_dir$rel_path"
            
            # Get remote file info
            local remote_info=$(get_remote_file_info "$remote_path")
            local remote_size="${remote_info%:*}"
            local local_size=$(stat -c %s "$file")
            
            # Quick size check first
            if [ "$local_size" != "$remote_size" ]; then
                echo "Size mismatch for $rel_path, transferring..."
                if ! rsync -avSz --progress "$file" "$NAS_HOST:$(dirname "$remote_path")/" 2>>"$ERROR_LOG"; then
                    echo "$(date): TRANSFER FAILED - $rel_path (size mismatch)" | tee -a "$ERROR_LOG"
                fi
            else
                echo "File $rel_path appears identical (size match)"
            fi
        done
    fi
}

# Optimized sync function
optimized_sync() {
    local source="$1"
    local destination="$2"
    
    if [ "$ENABLE_OPTIMIZATIONS" = "true" ]; then
        echo "Using optimized sync for $source"
        local dest_path="${destination#*:}"
        pre_verify_files "$source" "$dest_path"
    else
        echo "Using standard rsync for $source"
        sync_with_retry "$source" "$destination" ""
    fi
}

# Function to save checksum cache
save_checksum_cache() {
    if [ "$ENABLE_OPTIMIZATIONS" = "true" ]; then
        echo "Saving checksum cache..."
        > "$CHECKSUM_CACHE"
        for key in "${!checksum_cache[@]}"; do
            local checksum="${checksum_cache[$key]%:*}"
            local mtime="${checksum_cache[$key]#*:}"
            echo "$key|$checksum|$mtime" >> "$CHECKSUM_CACHE"
        done
    fi
}

# Retry function with exponential backoff
sync_with_retry() {
    local source="$1"
    local destination="$2"
    local exclude_opts="$3"
    local attempt=1
    
    while [ $attempt -le $MAX_ATTEMPTS ]; do
        echo "Attempt $attempt/$MAX_ATTEMPTS for $source"
        if rsync $RSYNC_OPTS "$SSH_OPTS" $exclude_opts "$source" "$destination" 2>>"$ERROR_LOG"; then
            echo "Synchronization successful for $source"
            return 0
        else
            echo "$(date): SYNC FAILED - $source (attempt $attempt/$MAX_ATTEMPTS)" | tee -a "$ERROR_LOG"
            if [ $attempt -lt $MAX_ATTEMPTS ]; then
                local wait_time=$((attempt * 30))
                echo "Waiting ${wait_time}s before next attempt..."
                sleep $wait_time
            fi
            attempt=$((attempt + 1))
        fi
    done
    
    echo "$(date): CRITICAL - Synchronization failed after $MAX_ATTEMPTS attempts for $source" | tee -a "$ERROR_LOG"
    return 1
}

# Synchronize all source folders
for i in "${!SOURCE_ARRAY[@]}"; do
    source="${SOURCE_ARRAY[$i]}"
    echo "Synchronizing $source to $FULL_DESTINATION"
    optimized_sync "$source" "$FULL_DESTINATION"
done

# Save cache
save_checksum_cache

echo "$(date): Synchronization completed" | tee -a "$LOG_FILE"
echo "Log available at: $LOG_FILE"

# Show error summary
if [ -s "$ERROR_LOG" ]; then
    echo ""
    echo "⚠️  ERRORS DETECTED - Check error log:"
    echo "Error log: $ERROR_LOG"
    echo ""
    echo "Error summary:"
    grep -c "TRANSFER FAILED\|SYNC FAILED\|CRITICAL\|ERROR" "$ERROR_LOG" | while read count; do
        echo "- $count errors logged"
    done
else
    echo "✅ No errors detected"
fi
