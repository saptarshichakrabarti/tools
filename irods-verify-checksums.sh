#!/usr/bin/env bash
#
# irods-verify-checksums.sh — Verify integrity between a local directory and an iRODS collection using checksums
#
# DESCRIPTION
#   irods-verify-checksums.sh compares cryptographic checksums of local files
#   against checksum metadata stored in iRODS. It verifies data integrity at
#   the content level, not just filenames or sizes.
#
# USAGE
#   ./irods-verify-checksums.sh [options]
# OPTIONS
#   -l PATH    Local directory to verify
#   -c PATH    iRODS collection path
#   -h         Show this help text
#
# EXAMPLES
#   ./irods-verify-checksums.sh
#   ./irods-verify-checksums.sh -l /data/projectA -c zone/home/projectA
#   ./irods-verify-checksums.sh -h
#
# EXIT STATUS
#       0  verification successful
#       1  mismatches detected
#       2  execution error

set -euo pipefail
IFS=$'\n\t'

# ------------------------- DEFAULT CONFIG -------------------------
LOCAL_DIR="HPC_intro"
IRODS_COLLECTION="LMIB/Saptarshi/HPC_intro"
# ------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: ./irods-verify-checksums.sh [options]
Options:
  -l PATH    Local directory to verify
  -c PATH    iRODS collection path
  -h         Show this help text
EOF
}

# ------------------------- ARG PARSING -----------------------------
while getopts "l:c:h" opt; do
    case "$opt" in
        l) LOCAL_DIR=$OPTARG ;;
        c) IRODS_COLLECTION=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

# ------------------------- LOGGING ---------------------------------
log_info()  { printf '[INFO] %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# ------------------------- REQUIRED COMMANDS ------------------------
required_cmds=(ipwd ichksum iquest sha256sum base64 awk sort diff mktemp find xxd)
for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        exit 2
    fi
done

# ------------------------- INPUT VALIDATION -------------------------
[ -d "$LOCAL_DIR" ] || { log_error "Local directory not found: $LOCAL_DIR"; exit 2; }

# ------------------------- TEMP FILES -------------------------------
LOCAL_MANIFEST=$(mktemp)
IRODS_MANIFEST=$(mktemp)
IRODS_RAW=$(mktemp)
cleanup() { rm -f "$LOCAL_MANIFEST" "$IRODS_MANIFEST" "$IRODS_RAW"; }
trap cleanup EXIT INT TERM

# ------------------------- MAIN PROCESS -----------------------------
log_info "Initializing verification process"

IRODS_ZONE_PATH=$(ipwd)
IRODS_ABS_PATH="${IRODS_ZONE_PATH%/}/${IRODS_COLLECTION#/}"

# ------------------------- CHECKSUM REGISTRATION --------------------
log_info "Registering iRODS checksums recursively"
ichksum -r "$IRODS_COLLECTION" >/dev/null

# ------------------------- LOCAL MANIFEST ---------------------------
log_info "Building local manifest from directory: $LOCAL_DIR"

TOTAL_FILES=$(find "$LOCAL_DIR" -type f | wc -l)
CURRENT=0
START_TIME=$SECONDS

find "$LOCAL_DIR" -type f -print0 | while IFS= read -r -d '' file; do
    CURRENT=$((CURRENT+1))
    rel_path="./${file#$LOCAL_DIR/}"
    hash=$(sha256sum "$file" | awk '{print $1}' | xxd -r -p | base64 | tr -d '\n')
    printf "%s  %s\n" "$hash" "$rel_path" >>"$LOCAL_MANIFEST"

    ELAPSED=$((SECONDS - START_TIME))
    if [ "$CURRENT" -gt 0 ]; then
        AVG_TIME_PER_FILE=$(echo "$ELAPSED / $CURRENT" | bc -l)
        REMAINING_EST=$(printf "%.0f" $(echo "$AVG_TIME_PER_FILE * ($TOTAL_FILES - $CURRENT)" | bc -l))
        printf '\r[INFO] Local manifest: %d/%d files processed (~%ds remaining)' \
            "$CURRENT" "$TOTAL_FILES" "$REMAINING_EST"
    fi
done < <(find "$LOCAL_DIR" -type f -print0)
printf '\n'

sort -k2 -o "$LOCAL_MANIFEST" "$LOCAL_MANIFEST"

# ------------------------- IRODS MANIFEST ---------------------------
log_info "Querying iRODS and building manifest"

QUERY1="SELECT COLL_NAME, DATA_NAME, DATA_CHECKSUM WHERE COLL_NAME = '$IRODS_ABS_PATH'"
QUERY2="SELECT COLL_NAME, DATA_NAME, DATA_CHECKSUM WHERE COLL_NAME LIKE '$IRODS_ABS_PATH/%'"

IRODS_QUERIES=("$QUERY1" "$QUERY2")
TOTAL_QUERIES=${#IRODS_QUERIES[@]}
CURRENT_QUERY=0

for Q in "${IRODS_QUERIES[@]}"; do
    CURRENT_QUERY=$((CURRENT_QUERY+1))
    iquest '%s/%s|%s' "$Q" 2>/dev/null | grep '|' >>"$IRODS_RAW" || true
    printf '\r[INFO] iRODS manifest: query %d/%d completed' "$CURRENT_QUERY" "$TOTAL_QUERIES"
done
printf '\n'

awk -v root="$IRODS_ABS_PATH" -F'|' '
{
    gsub(/sha2:|m:/, "", $2);
    sub("^" root, "./", $1);
    gsub(/\/+/, "/", $1);
    print $2 "  " $1
}' "$IRODS_RAW" | sort -k2 >"$IRODS_MANIFEST"

[ -s "$IRODS_MANIFEST" ] || { log_error "iRODS manifest empty"; exit 2; }

# ------------------------- COMPARISON -------------------------------
log_info "Comparing manifests"

if diff -u "$LOCAL_MANIFEST" "$IRODS_MANIFEST" >/dev/null; then
    printf 'Verification successful. All files match.\n'
    exit 0
else
    printf 'Verification discrepancies detected:\n'
    diff -u "$LOCAL_MANIFEST" "$IRODS_MANIFEST" \
        | grep -E '^[+-][^+-]' \
        | sed 's/^-/Local missing or different vs. iRODS: /' \
        | sed 's/^+/Present in iRODS or different vs local: /'
    exit 1
fi
