#!/usr/bin/env bash
set -euo pipefail

# =======================
# Defaults (edit as needed)
# =======================
REMOTE_BASE="b2:cozyhomes-www/backups"                     # rclone remote:bucket/prefix that holds your backups
DOWNLOAD_BASE="${HOME}/gocozyhomes-backups/b2/cozyhomes-downloads"
EXTRACT_TO="${HOME}/gocozyhomes-backups/b2/cozyhomes-extracts"
BWLIMIT="0"                                                # rclone bandwidth limit; "0" = unlimited
RCLONE_BIN="${RCLONE_BIN:-}"                               # optional override to rclone binary path

# Conservative defaults (good for small instances / shared hosting)
RCLONE_TRANSFERS="1"
RCLONE_CHECKERS="1"
RCLONE_B2_CHUNK="32M"
RCLONE_BUFFER="32M"

# Reliability
RCLONE_RETRIES="10"
RCLONE_LL_RETRIES="20"

# =======================
# Script options
# =======================
DO_LIST=false
DO_LATEST=false
DO_VERIFY_ZIPS=true              # now ON by default
DO_EXTRACT=true                  # extract by default to EXTRACT_TO
SELECT_NAME=""
EXTRACT_DIR_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: fetch_backup.sh [options]

Options:
  --list                 List available backup periods and exit.
  --latest               Auto-select the most recent backup period.
  --select NAME          Select a specific backup folder name (as listed).
  --verify-zips          Force-enable CRC test of each .zip (default: enabled).
  --no-verify-zips       Skip CRC tests.
  --extract DIR          Extract downloaded chunks into DIR (default: enabled to preset path).
  --no-extract           Do not extract after verification.
  --download-dir DIR     Change local download directory (default preset).
  --remote REMOTE        Change rclone remote base (default preset).
  -h, --help             Show this help and exit.
EOF
}

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
is_tty() { [[ -t 1 ]] || [[ -t 2 ]]; }

# Find rclone
find_rclone() {
  local candidates=(
    "$RCLONE_BIN"
    "$HOME/bin/rclone"
    "$HOME/.local/bin/rclone"
    "/usr/local/bin/rclone" "/usr/bin/rclone"
    "$(command -v rclone 2>/dev/null || true)"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}
RCLONE="$(find_rclone || true)"
if [[ -z "${RCLONE}" ]]; then
  echo "ERROR: rclone not found. Install rclone or set RCLONE_BIN=/path/to/rclone" >&2
  exit 1
fi

# ---------- Utilities ----------
list_periods() {
  "$RCLONE" lsf "$REMOTE_BASE" --dirs-only | sed 's:/$::' | awk 'NF'
}

period_sort_key() {
  awk '
  {
    name=$0
    date=""
    if (match(name, /[0-9]{4}-[0-9]{2}-[0-9]{2}$/)) { date=substr(name, RSTART, RLENGTH) }
    else if (match(name, /[0-9]{4}-W[0-9]{2}$/))   { date=substr(name, RSTART, RLENGTH) }
    else if (match(name, /[0-9]{4}-[0-9]{2}$/))    { date=substr(name, RSTART, RLENGTH) }
    else { date="0000-00" }
    print date "\t" name
  }'
}

choose_interactive() {
  local arr=("$@")
  {
    echo
    echo "Select a backup to download:"
    local i=1
    for x in "${arr[@]}"; do
      printf "  %2d) %s\n" "$i" "$x"
      i=$((i+1))
    done
    echo
  } >&2

  local choice
  while true; do
    read -rp "Enter a number (1-${#arr[@]}): " choice </dev/tty
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Please enter a valid number." >&2; continue; }
    (( choice>=1 && choice<=${#arr[@]} )) || { echo "Out of range." >&2; continue; }
    echo "${arr[$((choice-1))]}"
    return 0
  done
}

verify_remote_to_local_sizes() {
  local remote_dir="$1" local_dir="$2" filelist="$3"
  "$RCLONE" check "$remote_dir" "$local_dir" \
    --files-from "$filelist" \
    --checksum --one-way \
    --checkers="$RCLONE_CHECKERS" \
    --log-level=INFO --log-file="${DOWNLOAD_BASE}/fetch_check.log" \
    "${RCLONE_SNAPSHOT[@]}"
}

need_zip_lister() {
  if command -v unzip >/dev/null 2>&1; then
    echo "unzip"
  elif command -v zipinfo >/dev/null 2>&1; then
    echo "zipinfo"
  else
    echo ""
  fi
}

list_from_zip_chunks() {
  local chunks_root="$1"
  local lister; lister="$(need_zip_lister)"
  if [[ -z "$lister" ]]; then
    echo "ERROR: Neither unzip nor zipinfo found; cannot verify manifests." >&2
    return 2
  fi

  if ! compgen -G "$chunks_root/*.zip" >/dev/null 2>&1 && ! compgen -G "$chunks_root/**/*.zip" >/dev/null 2>&1; then
    echo "ERROR: No .zip chunks found under $chunks_root" >&2
    return 3
  fi

  if [[ "$lister" == "unzip" ]]; then
    find "$chunks_root" -type f -name '*.zip' -print0 \
    | xargs -0 -I{} unzip -Z1 "{}" \
    | sed -e '/\/$/d' -e 's#^\./##' \
    | LC_ALL=C sort -u
  else
    find "$chunks_root" -type f -name '*.zip' -print0 \
    | xargs -0 -I{} zipinfo -1 "{}" \
    | sed -e '/\/$/d' -e 's#^\./##' \
    | LC_ALL=C sort -u
  fi
}

compare_sorted_lists() {
  local expected="$1" actual="$2" tag="$3"
  local missing extra
  missing="$(comm -23 "$expected" "$actual" | wc -l | awk '{print $1}')"
  extra="$(comm -13 "$expected" "$actual" | wc -l | awk '{print $1}')"
  if (( missing > 0 )); then
    echo "ERROR: $missing paths are MISSING from downloaded chunks relative to $tag." >&2
    echo "Sample missing (up to 50):"
    comm -23 "$expected" "$actual" | head -n 50 >&2
    return 4
  fi
  if (( extra > 0 )); then
    echo "NOTE: $extra extra paths exist in downloaded chunks not present in $tag." >&2
    echo "Sample extra (up to 50):"
    comm -13 "$expected" "$actual" | head -n 50 >&2
  fi
  return 0
}

format_hms() {
  local sec="$1"
  printf "%02d:%02d:%02d" $((sec/3600)) $(((sec%3600)/60)) $((sec%60))
}

crc_test_zips_progress() {
  local root="$1"
  local -a files
  mapfile -t files < <(find "$root" -type f -name '*.zip' | LC_ALL=C sort)
  local total="${#files[@]}"
  if (( total == 0 )); then
    log "No zip files found for CRC."
    return 0
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    log "unzip not found; skipping CRC tests."
    return 0
  fi

  local start_ts now elapsed each_avg remain eta i=0 ok=0 bad=0 fname
  start_ts="$(date +%s)"
  echo
  echo "CRC testing $total chunk(s)…"
  for fname in "${files[@]}"; do
    i=$((i+1))
    now="$(date +%s)"
    elapsed=$(( now - start_ts ))
    each_avg=$(( i > 0 ? (elapsed / i) : 0 ))
    remain=$(( (total - i) * each_avg ))
    eta="$(format_hms "$remain")"
    short="$(basename "$fname")"
    printf "\r[%4d/%4d] ETA %s  %s" "$i" "$total" "$eta" "$short"
    if unzip -tqq "$fname" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      bad=$((bad+1))
      printf "\nCRC FAIL: %s\n" "$fname"
    fi
  done
  printf "\n"
  if (( bad > 0 )); then
    echo "ERROR: $bad/$total zip chunks failed CRC."
    return 1
  fi
  log "CRC OK for $ok/$total chunks."
}

extract_all() {
  local src_dir="$1" dest_dir="$2"
  mkdir -p "$dest_dir"
  local -a files
  mapfile -t files < <(find "$src_dir" -type f -name '*.zip' | LC_ALL=C sort)
  local total="${#files[@]}"
  if (( total == 0 )); then
    log "No zip files found to extract."
    return 0
  fi
  echo
  echo "Extracting $total chunk(s) into: $dest_dir"
  local i=0 short
  for z in "${files[@]}"; do
    i=$((i+1))
    short="$(basename "$z")"
    printf "\r[%4d/%4d] %s" "$i" "$total" "$short"
    (cd "$dest_dir" && unzip -n "$z" >/dev/null)
  done
  printf "\n"
  log "Extraction complete."
}

human_from_bytes() {
  awk -v b="$1" 'BEGIN{
    if(b<1024)         printf "%d B", b;
    else if(b<1048576) printf "%.0f KB", b/1024;
    else if(b<1073741824) printf "%.1f MB", b/1048576;
    else printf "%.2f GB", b/1073741824
  }'
}

# =======================
# Parse args
# =======================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) DO_LIST=true; shift ;;
    --latest) DO_LATEST=true; shift ;;
    --select) SELECT_NAME="${2:-}"; shift 2 ;;
    --verify-zips) DO_VERIFY_ZIPS=true; shift ;;
    --no-verify-zips) DO_VERIFY_ZIPS=false; shift ;;
    --extract) EXTRACT_DIR_OVERRIDE="${2:-}"; DO_EXTRACT=true; shift 2 ;;
    --no-extract) DO_EXTRACT=false; shift ;;
    --download-dir) DOWNLOAD_BASE="${2:-}"; shift 2 ;;
    --remote) REMOTE_BASE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

mkdir -p "$DOWNLOAD_BASE"

# 1) Build sorted list of periods
mapfile -t PERIODS < <(list_periods | period_sort_key | sort -k1,1 -k2,2 | awk -F'\t' '{print $2}')
if (( ${#PERIODS[@]} == 0 )); then
  echo "No backup periods found under $REMOTE_BASE" >&2
  exit 3
fi

if $DO_LIST; then
  printf "Available backups under %s:\n" "$REMOTE_BASE" >&2
  for p in "${PERIODS[@]}"; do echo "  $p" >&2; done
  exit 0
fi

# 2) Choose target
TARGET=""
if [[ -n "$SELECT_NAME" ]]; then
  TARGET="$SELECT_NAME"
elif $DO_LATEST; then
  TARGET="${PERIODS[-1]}"
else
  TARGET="$(choose_interactive "${PERIODS[@]}")"
fi
if [[ -z "$TARGET" ]]; then
  echo "No selection made; exiting." >&2
  exit 2
fi

REMOTE_DIR="${REMOTE_BASE}/${TARGET}"
LOCAL_DIR="${DOWNLOAD_BASE}/${TARGET}"
mkdir -p "$LOCAL_DIR"

# Freeze the view of the bucket to avoid racing uploads
SNAP_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RCLONE_SNAPSHOT=( --b2-version-at="$SNAP_TS" )

# Pre-flight: ensure the remote period actually contains zip chunks and is sealed
if ! "$RCLONE" lsf "$REMOTE_DIR" --files-only --include "*.zip" "${RCLONE_SNAPSHOT[@]}" >/dev/null 2>&1; then
  echo "ERROR: No .zip chunks found on remote in: $REMOTE_DIR" >&2
  echo "Available items there:" >&2
  "$RCLONE" lsf "$REMOTE_DIR" "${RCLONE_SNAPSHOT[@]}" >&2 || true
  exit 4
fi
if ! "$RCLONE" lsf "$REMOTE_DIR" --files-only --include "UPLOADED.OK" "${RCLONE_SNAPSHOT[@]}" >/dev/null 2>&1; then
  echo "Backup not sealed yet: UPLOADED.OK missing in ${REMOTE_DIR}. Try again later." >&2
  exit 4
fi

# 2.5) Build explicit (RECURSIVE) file list & compute total size
WORK_DIR="$(mktemp -d "${DOWNLOAD_BASE}/dl_${TARGET}_XXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
FILELIST="${WORK_DIR}/files.txt"

# >>> FIX: recursive lsf so subfolders like sql/*.gz are included
"$RCLONE" lsf "$REMOTE_DIR" --files-only -R "${RCLONE_SNAPSHOT[@]}" > "$FILELIST"

TOTAL_BYTES=0
while IFS= read -r f; do
  sz="$("$RCLONE" lsl "$REMOTE_DIR" --include "$f" "${RCLONE_SNAPSHOT[@]}" | awk '{s=$1} END{print s+0}')" || sz=0
  TOTAL_BYTES=$(( TOTAL_BYTES + sz ))
done < "$FILELIST"

log "Preparing to download: $TARGET"
log "Total files: $(wc -l < "$FILELIST" | awk '{print $1}'); Total size: $(human_from_bytes "$TOTAL_BYTES")"

# Sanity: free space >= total * 1.2
FREE_BYTES=$(df -P "$LOCAL_DIR" | awk 'NR==2{print $4*1024}')
if (( FREE_BYTES < TOTAL_BYTES * 12 / 10 )); then
  echo "ERROR: Not enough free space. Need ~$(human_from_bytes $((TOTAL_BYTES*12/10))) free." >&2
  exit 7
fi

# 3) Download with live progress bars when interactive
RCLONE_COMMON_ARGS=(
  --transfers="$RCLONE_TRANSFERS" --checkers="$RCLONE_CHECKERS"
  --b2-chunk-size="$RCLONE_B2_CHUNK" --b2-upload-cutoff="$RCLONE_B2_CHUNK"
  --buffer-size="$RCLONE_BUFFER" --bwlimit="$BWLIMIT"
  --disable-http2
  --retries="$RCLONE_RETRIES" --low-level-retries="$RCLONE_LL_RETRIES" --retries-sleep=2s
  --log-level=INFO --log-file="${DOWNLOAD_BASE}/fetch_copy.log"
  "${RCLONE_SNAPSHOT[@]}"
)

if is_tty; then
  echo
  echo "Downloading with live progress (per-file + overall ETA)…"
  echo
  "$RCLONE" copy "$REMOTE_DIR" "$LOCAL_DIR" \
    --files-from "$FILELIST" \
    --progress --stats=1s --stats-file-name-length 64 \
    "${RCLONE_COMMON_ARGS[@]}"
else
  log "Non-interactive session detected: running without live progress UI."
  "$RCLONE" copy "$REMOTE_DIR" "$LOCAL_DIR" \
    --files-from "$FILELIST" \
    "${RCLONE_COMMON_ARGS[@]}"
fi

# Sanity check: confirm we actually received some chunks
if ! compgen -G "$LOCAL_DIR/*.zip" >/dev/null 2>&1 && ! compgen -G "$LOCAL_DIR/**/*.zip" >/dev/null 2>&1; then
  echo "ERROR: Download completed but no .zip chunks found under $LOCAL_DIR" >&2
  exit 5
fi

# 4) Verify remote -> local using the SAME list you copied (and checksums)
log "Verifying remote -> local by checksum (limited to FILELIST)…"
if ! verify_remote_to_local_sizes "$REMOTE_DIR" "$LOCAL_DIR" "$FILELIST"; then
  echo "ERROR: Verification failed. See ${DOWNLOAD_BASE}/fetch_check.log" >&2
  exit 6
fi
log "Verification OK."

# 5) Manifest-based verification (compare ZIP contents to expected/archived lists)
EXPECTED_MAN="${LOCAL_DIR}/manifest.expected"
ARCHIVED_MAN="${LOCAL_DIR}/manifest.archived"
REL_LIST="${WORK_DIR}/from_zips.sorted"

log "Building file list from downloaded chunks…"
list_from_zip_chunks "$LOCAL_DIR" > "$REL_LIST"

if [[ -s "$EXPECTED_MAN" ]]; then
  log "Verifying ZIP contents against manifest.expected…"
  EXP_SORTED="${WORK_DIR}/expected.sorted"
  LC_ALL=C sort -u "$EXPECTED_MAN" > "$EXP_SORTED"
  compare_sorted_lists "$EXP_SORTED" "$REL_LIST" "manifest.expected"
  log "Manifest.expected verification OK."
elif [[ -s "$ARCHIVED_MAN" ]]; then
  log "manifest.expected not found; verifying against manifest.archived…"
  ARC_SORTED="${WORK_DIR}/archived.sorted"
  LC_ALL=C sort -u "$ARCHIVED_MAN" > "$ARC_SORTED"
  compare_sorted_lists "$ARC_SORTED" "$REL_LIST" "manifest.archived"
  log "Manifest.archived verification OK."
else
  echo "WARNING: Neither manifest.expected nor manifest.archived found in $LOCAL_DIR; skipping manifest verification." >&2
fi

# 6) CRC test for each zip (default enabled) with progress
if $DO_VERIFY_ZIPS; then
  crc_test_zips_progress "$LOCAL_DIR"
fi

# 7) Extraction (default enabled) — EXTRACT_TO unless overridden
if $DO_EXTRACT; then
  DEST_DIR="$EXTRACT_TO"
  [[ -n "$EXTRACT_DIR_OVERRIDE" ]] && DEST_DIR="$EXTRACT_DIR_OVERRIDE"
  log "Extracting into: $DEST_DIR"
  extract_all "$LOCAL_DIR" "$DEST_DIR"
fi

log "Done. Downloaded archive is in: $LOCAL_DIR"
if [[ -f "$LOCAL_DIR/UPLOADED.OK" ]]; then
  log "UPLOADED.OK present in the downloaded archive."
else
  log "NOTE: UPLOADED.OK not found in the downloaded archive."
fi

