#!/usr/bin/env bash
#
# iRODS Verification Script
#
# This script verifies the integrity of files in a local directory against
# their counterparts stored in an iRODS collection. It uses SHA-256 hashes
# to detect any differences between local and remote files.
#
# Features:
#   - Caches file metadata (size, mtime, hash) to avoid re-hashing unchanged files
#   - Parallel hash computation for improved performance
#   - Compares local files with iRODS checksums
#   - Optional: Updates iRODS AVUs (Attribute-Value-Unit) with verification metadata
#
# Usage:
#   verify.sh [OPTIONS]
#
# Options:
#   --update-avu    Update iRODS AVUs with verification metadata (default: audit-only)
#   -l DIR          Local directory to verify (default: "FOCUS")
#   -c COLLECTION   iRODS collection path (default: "LMIB/Saptarshi/FOCUS")
#   -j JOBS         Number of parallel hash jobs (default: number of CPU cores)
#
# Requirements:
#   - jq: JSON processing
#   - openssl: SHA-256 hash computation
#   - iquest, imeta, ipwd: iRODS command-line tools
#   - stat, find, xargs: Standard Unix utilities
#
# Exit codes:
#   0: Verification successful (all files match)
#   1: Differences detected or verification failed
#   2: Error in script execution or missing dependencies
#
# Cache file:
#   The script maintains a JSON cache (.irods_verify_cache.json) that stores
#   file metadata to avoid re-hashing files that haven't changed (based on
#   size and modification time).
#

set -euo pipefail
IFS=$'\n\t'

# ---------------- CONFIG ----------------
LOCAL_DIR="FOCUS"
IRODS_COLLECTION="LMIB/Saptarshi/FOCUS"

CACHE_JSON=".irods_verify_cache.json"
PARALLEL_JOBS=$(nproc)
AUDIT_ONLY=1   # default: read-only

# ----------------------------------------

# Logging functions
log()  { printf '[INFO] %s\n' "$*"; }   # Info messages to stdout
warn() { printf '[WARN] %s\n' "$*" >&2; }  # Warnings to stderr
err()  { printf '[ERROR] %s\n' "$*" >&2; } # Errors to stderr

# ---------------- ARG PARSING ------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update-avu) AUDIT_ONLY=0 ;;
        -l) LOCAL_DIR=$2; shift ;;
        -c) IRODS_COLLECTION=$2; shift ;;
        -j) PARALLEL_JOBS=$2; shift ;;
        *) err "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

# ---------------- VALIDATION -------------
for cmd in jq openssl iquest stat find xargs; do
    command -v "$cmd" >/dev/null || { err "$cmd not found"; exit 2; }
done

[ -d "$LOCAL_DIR" ] || { err "Local directory not found"; exit 2; }

# ---------------- IRODS PATH -------------
# Get current iRODS zone and construct absolute collection path
IRODS_ZONE=$(ipwd)
IRODS_ABS="${IRODS_ZONE%/}/${IRODS_COLLECTION#/}"

# ---------------- CACHE INIT -------------
if [[ -f "$CACHE_JSON" ]]; then
    log "Loading JSON cache"
else
    log "No cache found; initializing"
    echo '{}' >"$CACHE_JSON"
fi

# ---------------- FILE ENUMERATION -------
# Find all files in the local directory (null-delimited for safety with special chars)
mapfile -d '' FILES < <(find "$LOCAL_DIR" -type f -print0 || true)
TOTAL=${#FILES[@]}

(( TOTAL > 0 )) || { warn "No files found"; exit 0; }

log "Found $TOTAL local files"

# ---------------- CHANGE DETECTION -------
# Check cache to determine which files need re-hashing
# Skip files that haven't changed (same size and mtime)
TO_HASH=()

for f in "${FILES[@]}"; do
    # Get relative path from local directory root
    rel="./${f#$LOCAL_DIR/}"
    size=$(stat -c %s "$f")
    mtime=$(stat -c %Y "$f")

    # Check if file exists in cache with matching size and mtime
    # If match found, skip hashing (use cached hash)
    if jq -e --arg p "$rel" \
          '.[$p] and .[$p].size == $size and .[$p].mtime == $mtime' \
          --argjson size "$size" \
          --argjson mtime "$mtime" \
          "$CACHE_JSON" >/dev/null 2>&1; then
        continue
    fi

    # File changed or not in cache - needs hashing
    TO_HASH+=("$f")
done

log "${#TO_HASH[@]} files require hashing"

# ---------------- PARALLEL HASHING -------
# Compute SHA-256 hashes for changed files in parallel
# Each job outputs a JSON object with file metadata
TMP_HASH=$(mktemp)

if (( ${#TO_HASH[@]} > 0 )); then
    # Process files in parallel using xargs
    # -0: null-delimited input
    # -n1: one argument per command
    # -P: number of parallel jobs
    printf '%s\0' "${TO_HASH[@]}" |
    xargs -0 -n1 -P "$PARALLEL_JOBS" bash -c '
        f="$1"
        rel="./${f#'"$LOCAL_DIR"'/}"
        size=$(stat -c %s "$f")
        mtime=$(stat -c %Y "$f")
        # Compute SHA-256 hash and encode as base64
        hash=$(openssl dgst -sha256 -binary "$f" | base64 -w 0)

        # Output JSON object with file metadata
        jq -n \
          --arg p "$rel" \
          --arg h "$hash" \
          --argjson s "$size" \
          --argjson m "$mtime" \
          "{(\$p): {size: \$s, mtime: \$m, hash: \$h}}"
    ' bash >>"$TMP_HASH"
fi

# ---------------- CACHE MERGE ------------
# Merge new hash results into the cache
# -s: slurp mode (read all inputs into array)
# reduce: merge all objects into one
if [[ -s "$TMP_HASH" ]]; then
    jq -s 'reduce .[] as $i ({}; . * $i)' \
        "$CACHE_JSON" "$TMP_HASH" >"$CACHE_JSON.new"
    mv "$CACHE_JSON.new" "$CACHE_JSON"
fi

rm -f "$TMP_HASH"

# ---------------- LOCAL MANIFEST ---------
# Generate manifest: tab-separated path and hash for all local files
TMP_LOCAL=$(mktemp)
jq -r 'to_entries[] | "\(.key)\t\(.value.hash)"' \
   "$CACHE_JSON" | LC_ALL=C sort >"$TMP_LOCAL"

# ---------------- IRODS MANIFEST ---------
# Query iRODS for checksums and generate comparable manifest
TMP_IRODS=$(mktemp)

# Query iRODS for collection name, data name, and checksum
iquest "%s/%s|%s" \
  "SELECT COLL_NAME, DATA_NAME, DATA_CHECKSUM WHERE COLL_NAME LIKE '$IRODS_ABS%'" |
# Process iRODS output:
# - Remove "sha2:" prefix from checksums
# - Normalize paths to start with "./" for comparison
awk -F'|' -v root="$IRODS_ABS" '
{
    gsub(/^sha2:/,"",$2)  # Remove sha2: prefix from checksum
    sub("^"root,"./",$1)  # Normalize path to relative format
    print $1 "\t" $2      # Output: path<tab>hash
}' | LC_ALL=C sort >"$TMP_IRODS"

# ---------------- COMPARE ----------------
# Compare local and iRODS manifests to detect differences
log "Comparing manifests"

if diff -u "$TMP_LOCAL" "$TMP_IRODS" >/dev/null; then
    log "Verification successful"
    exit 0
fi

# Show differences in a readable format
# - lines starting with - are in local but not iRODS (or hash mismatch)
# - lines starting with + are in iRODS but not local (or hash mismatch)
warn "Differences detected"
diff -u "$TMP_LOCAL" "$TMP_IRODS" |
grep -E '^[+-]\./' |
sed 's/^-/LOCAL: /; s/^+/IRODS: /'

# ---------------- OPTIONAL AVU UPDATE ---
# Update iRODS AVUs (Attribute-Value-Unit) with verification metadata
# This is only done if --update-avu flag is provided
if (( AUDIT_ONLY == 0 )); then
    log "Updating iRODS AVUs"
    NOW=$(date +%s)
    # For each file in local manifest, set AVUs:
    # - verify.sha256: the SHA-256 hash
    # - verify.last_checked: timestamp of last verification
    while IFS=$'\t' read -r path hash; do
        obj="$IRODS_ABS/${path#./}"
        imeta set -d "$obj" verify.sha256 "$hash" local >/dev/null 2>&1 || true
        imeta set -d "$obj" verify.last_checked "$NOW" epoch >/dev/null 2>&1 || true
    done <"$TMP_LOCAL"
else
    log "Audit-only mode: no AVUs updated"
fi

exit 1
