#!/usr/bin/env bash
#
# irods-verify-checksums.sh — Verify integrity between a local directory and an iRODS collection using checksums
#
# DESCRIPTION
#   irods-verify-checksums.sh compares cryptographic checksums of local files
#   against checksum metadata stored in iRODS. It verifies data integrity at
#   the content level, not just filenames or sizes.
#
# WHAT THE SCRIPT DOES
#   1) Ensures iRODS checksums are registered (ichksum -r)
#   2) Builds a local manifest using SHA-256 (Base64-encoded)
#   3) Queries iRODS for stored checksums
#   4) Normalizes both file path lists
#   5) Compares manifests and reports discrepancies
#
# TYPICAL USE CASES
#   • Validation after ingest or upload to iRODS
#   • Periodic data integrity audits
#   • Verification before archival or deletion
#   • Quality control in research data management workflows
#
# REQUIREMENTS
#   iRODS client tools:
#       ipwd, ichksum, iquest
#   Standard Unix utilities:
#       sha256sum, base64, awk, diff, sort, xxd, mktemp, find
#
# USAGE
#   ./irods-verify-checksums.sh [options]
#
# OPTIONS
#   -l PATH    Local directory to verify
#   -c PATH    iRODS collection path
#   -h         Show help text
#
# EXAMPLES
#   Verify using defaults configured inside the script:
#       ./irods-verify-checksums.sh
#
#   Verify explicit directory and iRODS collection:
#       ./irods-verify-checksums.sh -l /data/projectA -c zone/home/projectA
#
#   Display help:
#       ./irods-verify-checksums.sh -h
#
# EXIT STATUS
#       0  verification successful (all files match)
#       1  mismatches detected
#       2  validation or execution error
#
# NOTES
#   • Only regular files are processed
#   • Relative paths are normalized and prefixed with "./"
#   • Designed for bash; uses bash-only features (arrays, pipefail, process substitution)

set -euo pipefail
IFS=$'\n\t'

# ------------------------- DEFAULT CONFIG -------------------------
LOCAL_DIR="HPC_intro"
IRODS_COLLECTION="LMIB/Saptarshi/HPC_intro"
# ------------------------------------------------------------------

usage() {
    cat <<'EOF'
Verify integrity of a local directory against checksum metadata stored in iRODS.

Options:
  -l PATH    Local directory to verify
  -c PATH    iRODS collection path
  -h         Show this help text and exit

Examples:
  # Use defaults configured in the script
  ./irods-verify-checksums.sh

  # Verify custom local directory and iRODS collection
  ./irods-verify-checksums.sh -l /data/projectA -c zone/home/projectA

  # Show help
  ./irods-verify-checksums.sh -h

Exit codes:
  0  verification successful (all files match)
  1  mismatches detected
  2  failure during execution or validation error
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
if [ ! -d "$LOCAL_DIR" ]; then
    log_error "Local directory not found or not accessible: $LOCAL_DIR"
    exit 2
fi

# ------------------------- TEMP FILES -------------------------------
LOCAL_MANIFEST=$(mktemp)
IRODS_MANIFEST=$(mktemp)
IRODS_RAW=$(mktemp)

cleanup() {
    rm -f "$LOCAL_MANIFEST" "$IRODS_MANIFEST" "$IRODS_RAW"
}
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

while IFS= read -r -d '' file; do
    rel_path="./${file#$LOCAL_DIR/}"
    hash=$(sha256sum "$file" | awk '{print $1}' | xxd -r -p | base64 | tr -d '\n')
    printf "%s  %s\n" "$hash" "$rel_path" >>"$LOCAL_MANIFEST"
done < <(find "$LOCAL_DIR" -type f -print0)

sort -k2 -o "$LOCAL_MANIFEST" "$LOCAL_MANIFEST"

# ------------------------- IRODS MANIFEST ---------------------------
log_info "Querying iRODS and building manifest"

QUERY1="SELECT COLL_NAME, DATA_NAME, DATA_CHECKSUM WHERE COLL_NAME = '$IRODS_ABS_PATH'"
QUERY2="SELECT COLL_NAME, DATA_NAME, DATA_CHECKSUM WHERE COLL_NAME LIKE '$IRODS_ABS_PATH/%'"

for Q in "$QUERY1" "$QUERY2"; do
    iquest '%s/%s|%s' "$Q" 2>/dev/null | grep '|' >>"$IRODS_RAW" || true
done

awk -v root="$IRODS_ABS_PATH" -F'|' '
{
    gsub(/sha2:|m:/, "", $2);
    sub("^" root, "./", $1);
    gsub(/\/+/, "/", $1);
    print $2 "  " $1
}' "$IRODS_RAW" | sort -k2 >"$IRODS_MANIFEST"

if [ ! -s "$IRODS_MANIFEST" ]; then
    log_error "No data found in iRODS manifest; path may be incorrect or inaccessible"
    exit 2
fi

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
