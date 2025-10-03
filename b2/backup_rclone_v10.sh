#!/usr/bin/env bash
set -euo pipefail

# Safer defaults for cron environments
export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
umask 077

# ========= USER CONFIG =========
HOME_DIR="/home4/uhdtdbmy"
SOURCE_DIR="$HOME_DIR/public_html/gocozyhomes"                  # directory to back up
#SOURCE_DIR="$HOME_DIR/gocozyhomes-backups/b2/testdata"
BACKUP_DIR="$HOME_DIR/gocozyhomes-backups/b2/backups"           # local folder to store archives
REMOTE="b2:cozyhomes-www/backups"                               # rclone remote:bucket/path
KEEP_LOCAL_DAYS=90                                              # days to keep local archives
KEEP_REMOTE_DAYS=3650                                           # days to keep remote archives
EXCLUDES_FILE=""                                                # optional: exclude patterns file (one per line)
BWLIMIT="0"                                                     # rclone bandwidth limit (e.g., "4M"); "0" = unlimited
LOG_FILE="$HOME_DIR/gocozyhomes-backups/b2/logs/backup_rclone.log"

# How often to create a new backup: daily | weekly | monthly
BACKUP_FREQUENCY="monthly"

# Verify even when reusing a local chunk set (0/1)
VERIFY_REUSED_ARCHIVE=1
# Limit how many differing paths to print in logs/email
MAX_DIFF_LINES=200

# Email (sendmail only)
MAIL_TO="gocozyhomes2021@gmail.com"
MAIL_FROM="do-not-reply@gocozyhomes.com"
MAIL_SUBJECT_PREFIX="[Backup GoCozyHomes]"

# Database (use ~/.my.cnf; leave USER/PASS blank)
DB_HOST=""                 # empty -> defaults to localhost
DB_USER=""                 # leave empty to use ~/.my.cnf
DB_PASS=""                 # leave empty to use ~/.my.cnf
DBS=("uhdtdbmy_cozyhomes")

# ---- chunked archiving config ----
# Per-run cap for how much compressed data we CREATE
CHUNK_BUDGET_MB=51200                      # e.g., 51200MB (~50GB) max new chunks per run
# Target size for each chunk zip (creation batches)
CHUNK_TARGET_MB=1500                       # create zips about this big each
# =================================

DATE="$(date +'%Y-%m-%d')"
START_TS=$(date +%s)
HOST="$(hostname)"

case "${BACKUP_FREQUENCY}" in
  daily)   PERIOD_TAG="$(date +'%Y-%m-%d')" ;;
  weekly)  PERIOD_TAG="$(date +'%G-W%V')" ;;     # ISO week
  monthly) PERIOD_TAG="$(date +'%Y-%m')" ;;
  *)       PERIOD_TAG="$(date +'%Y-%m')" ;;
esac

# Unique prefix from SOURCE_DIR path for safety across different sources
PREFIX_RAW="${SOURCE_DIR%/}"
PREFIX_SAFE="$(printf '%s' "${PREFIX_RAW#/}" | tr '/ ' '__' | tr -cs 'A-Za-z0-9._-' '_' )"
PREFIX_HASH="$(printf '%s' "$PREFIX_RAW" | { sha1sum 2>/dev/null || shasum 2>/dev/null || md5sum 2>/dev/null; } | awk '{print substr($1,1,8)}')"
[[ -z "$PREFIX_HASH" ]] && PREFIX_HASH="nohash"
UNIQUE_PREFIX="${PREFIX_SAFE}_${PREFIX_HASH}"

# Base name for this period (folder + file stems)
BASENAME="${UNIQUE_PREFIX}_${PERIOD_TAG}"

WORK_DIR="$(mktemp -d /tmp/backup_${PERIOD_TAG}_XXXX)"
mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

# Chunk layout
PARTS_DIR="$BACKUP_DIR/${BASENAME}.parts"     # local folder holding all chunks & manifests
CHUNK_PREFIX="$BASENAME.chunk"                # chunks look like: <prefix>-0001.zip, -0002.zip ...
UPLOAD_MARKER="UPLOADED.OK"                   # marker file placed after successful remote upload

# Manifests (inside PARTS_DIR)
MANIFEST_EXPECTED="$PARTS_DIR/manifest.expected"
MANIFEST_DONE="$PARTS_DIR/manifest.done"
MANIFEST_ARCHIVED="$PARTS_DIR/manifest.archived"

STATUS="SUCCESS"
ERROR_MSG=""
SKIPPED_REMOTE=false
EXPECTED_COUNT=""
ARCHIVED_COUNT=""
MISSING_COUNT=""
EXTRA_COUNT=""
CREATED_CHUNKS=0
CREATED_BYTES=0
SEND_EMAIL=false
UPLOAD_COMPLETED=false

# ---------- Helpers ----------
send_email() {
  local subject="$1" body="$2"
  local sm="/usr/sbin/sendmail"; [[ -x /usr/lib/sendmail ]] && sm="/usr/lib/sendmail"
  if [[ -x "$sm" ]]; then
    { printf "To: %s\nFrom: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n" \
        "$MAIL_TO" "$MAIL_FROM" "$subject" "$body"; } | "$sm" -t
  else
    { echo "=== EMAIL (sendmail not found) ==="; echo "Subject: $subject"; echo "$body"; echo "==============================="; } >> "$LOG_FILE"
  fi
}

bytes_from_human_mb() { awk -v m="$1" 'BEGIN{print int(m*1024*1024)}'; }
human_from_bytes()    { awk -v b="$1" 'BEGIN{if(b<1024)printf "%dB",b; else if(b<1048576)printf "%dK",b/1024; else if(b<1073741824)printf "%dM",b/1048576; else printf "%.1fG",b/1073741824}'; }

zip_test() {
  local z="$1"
  if command -v unzip >/dev/null 2>&1; then
    unzip -tqq "$z" >/dev/null
  elif command -v zip >/dev/null 2>&1; then
    zip -T "$z" >/dev/null
  else
    echo "WARN: no unzip/zip test available; skipping integrity test for $z" | tee -a "$LOG_FILE"
    return 0
  fi
}

list_archived_entries() {
  local z
  if compgen -G "$PARTS_DIR/${CHUNK_PREFIX}-*.zip" >/dev/null 2>&1; then
    for z in "$PARTS_DIR"/${CHUNK_PREFIX}-*.zip; do
      if command -v unzip >/dev/null 2>&1; then
        unzip -Z1 "$z"
      elif command -v zipinfo >/dev/null 2>&1; then
        zipinfo -1 "$z"
      elif command -v zip >/dev/null 2>&1; then
        # Fallback: zip -sf prints a report; extract just names
        zip -sf "$z" | sed -n '/^  listing of: /,$p' | sed '1,2d'
      fi
    done | sed -e '/\/$/d' -e 's#^./##' | LC_ALL=C sort -u
  fi
}

file_size_bytes() {
  local p="$1"
  if [[ -e "$p" ]]; then
    if stat -c%s "$p" >/dev/null 2>&1; then
      stat -c%s "$p"
    elif stat -f%z "$p" >/dev/null 2>&1; then
      stat -f%z "$p"
    else
      wc -c <"$p" 2>/dev/null || echo 0
    fi
  else
    echo 0
  fi
}

# ---------- Locate rclone ----------
RCLONE_BIN="${RCLONE_BIN:-}"
find_rclone() {
  local candidates=(
    "$RCLONE_BIN"
    "$HOME_DIR/bin/rclone"
    "$HOME_DIR/.local/bin/rclone"
    "$HOME/bin/rclone"
    "$(command -v rclone 2>/dev/null || true)"
    "/usr/local/bin/rclone" "/usr/bin/rclone"
  )
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}
RCLONE="$(find_rclone || true)"

on_error() {
  local exit_code=$?
  STATUS="FAILURE"
  ERROR_MSG="Command failed (exit $exit_code): $BASH_COMMAND"
  SEND_EMAIL=true
  return $exit_code
}
trap on_error ERR

# ----- Remote completeness helpers -----
remote_is_complete() {
  # Compare LOCAL parts dir vs REMOTE by size only (fast, catches 0-byte/partial files).
  # Return 0 if everything on remote matches, 1 otherwise.
  "$RCLONE" check "$PARTS_DIR" "$REMOTE_PREFIX" \
    --size-only --one-way --checkers=1 --log-level=INFO --log-file="$LOG_FILE" \
    --exclude "UPLOADED.OK" >/dev/null 2>&1
}

delete_remote_marker_if_present() {
  if "$RCLONE" lsf "$REMOTE_PREFIX" --include "UPLOADED.OK" >/dev/null 2>&1; then
    "$RCLONE" delete "$REMOTE_PREFIX" --include "UPLOADED.OK" \
      --log-level=INFO --log-file="$LOG_FILE" || true
  fi
}

write_remote_marker() {
  # Only call this AFTER remote_is_complete returns success.
  {
    echo "OK ${DATE}"
    echo "host=${HOST}"
    echo "period=${BASENAME}"
    echo "chunks_local_count=$(find "$PARTS_DIR" -maxdepth 1 -type f -name '*.zip' | wc -l | awk '{print $1}')"
  } | "$RCLONE" rcat "$REMOTE_PREFIX/UPLOADED.OK" \
       --log-level=INFO --log-file="$LOG_FILE"
}

finish() {
  local end_ts duration_s duration_hms log_tail now
  end_ts=$(date +%s)
  duration_s=$(( end_ts - START_TS ))
  duration_hms=$(printf "%02d:%02d:%02d" $((duration_s/3600)) $(((duration_s%3600)/60)) $((duration_s%60)))

  # Chunk stats
  local CHUNK_LOCAL_COUNT=0 CHUNK_LOCAL_BYTES=0 CHUNK_BYTES_HUMAN="n/a" SQL_BYTES=0 SQL_SIZE_HUMAN="n/a"
  if compgen -G "$PARTS_DIR/${CHUNK_PREFIX}-*.zip" >/dev/null 2>&1; then
    CHUNK_LOCAL_COUNT="$(ls "$PARTS_DIR"/${CHUNK_PREFIX}-*.zip | wc -l | awk '{print $1}')"
    CHUNK_LOCAL_BYTES="$(du -cb "$PARTS_DIR"/${CHUNK_PREFIX}-*.zip | tail -1 | awk '{print $1}')"
    CHUNK_BYTES_HUMAN="$(human_from_bytes "$CHUNK_LOCAL_BYTES")"
  fi
  if compgen -G "$PARTS_DIR/sql/*.gz" >/dev/null 2>&1; then
    SQL_BYTES="$(du -cb "$PARTS_DIR"/sql/*.gz | tail -1 | awk '{print $1}')"
    SQL_SIZE_HUMAN="$(human_from_bytes "$SQL_BYTES")"
  fi

  now="$(date -Is)"
  log_tail="$(tail -n 60 "$LOG_FILE" 2>/dev/null || true)"

  # Build subject per policy:
  # - FAILURE: always email with reason
  # - SUCCESS with upload completed: email with total uploaded size + period
  # - Otherwise (skipped / partial): no email
  local subject=""
  if [[ "$STATUS" = "FAILURE" ]]; then
    subject="${MAIL_SUBJECT_PREFIX} FAILURE: ${ERROR_MSG} - ${BASENAME}"
    SEND_EMAIL=true
  elif [[ "$UPLOAD_COMPLETED" == true ]]; then
    subject="${MAIL_SUBJECT_PREFIX} SUCCESS: uploaded ${CHUNK_BYTES_HUMAN} - ${BASENAME}"
    SEND_EMAIL=true
  else
    SEND_EMAIL=false
  fi

  read -r -d '' body <<EOF || true
Backup status: ${STATUS}
Host: ${HOST}
Date: ${DATE}
Period: ${BACKUP_FREQUENCY} (${BASENAME})

Source dir: ${SOURCE_DIR}
Local parts dir: ${PARTS_DIR}
Chunk files: ${CHUNK_LOCAL_COUNT} (${CHUNK_BYTES_HUMAN})
New chunks this run: ${CREATED_CHUNKS} (~$(human_from_bytes "$CREATED_BYTES"))
DB dumps (compressed): ${SQL_SIZE_HUMAN}

Verify counts — expected: ${EXPECTED_COUNT:-n/a}, archived: ${ARCHIVED_COUNT:-n/a}, missing: ${MISSING_COUNT:-0}, extra: ${EXTRA_COUNT:-0}

Remote target (folder): ${REMOTE}/${BASENAME}
rclone path: ${RCLONE:-not found}
Log file: ${LOG_FILE}
Finished at: ${now}
Duration: ${duration_hms}

$( [[ "$STATUS" = "FAILURE" ]] && echo "Error: ${ERROR_MSG}" )

--- Last 60 log lines ---
${log_tail}
EOF

  if [[ "$SEND_EMAIL" == true ]]; then
    send_email "$subject" "$body"
  fi
  rm -rf "$WORK_DIR"
}
trap finish EXIT

# --------- start ---------
echo "[$(date -Is)] Starting backup for period ${BASENAME}" | tee -a "$LOG_FILE"

# Fail early if rclone missing
if [[ -z "${RCLONE:-}" ]]; then
  echo "ERROR: rclone not found. Install it under \$HOME/bin or set RCLONE_BIN=/full/path/to/rclone" | tee -a "$LOG_FILE"
  STATUS="FAILURE"; ERROR_MSG="rclone not found"; exit 6
fi

# Prevent overlapping runs
LOCKFILE="/tmp/backup_to_b2.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "Another backup is running; exiting." | tee -a "$LOG_FILE"
  STATUS="FAILURE"; ERROR_MSG="Lockfile in use"; exit 1
fi

# ---------- MySQL dump options ----------
: "${DB_HOST:=localhost}"
MYSQL_OPTS=(--host="$DB_HOST" --single-transaction --quick --hex-blob)
[[ -n "${DB_USER:-}" ]] && MYSQL_OPTS+=(--user="$DB_USER")
[[ -n "${DB_PASS:-}" ]] && MYSQL_OPTS+=(--password="$DB_PASS")

# Remote base for this period
REMOTE_PREFIX="${REMOTE}/${BASENAME}"

# ---------- Remote skip check (marker is not trusted unless remote is complete) ----------
if remote_is_complete; then
  echo "Remote already complete and verified for ${BASENAME}. Skipping upload." | tee -a "$LOG_FILE"
  STATUS="SUCCESS"; SKIPPED_REMOTE=true
  exit 0
fi
# If a stale marker exists while remote is incomplete, remove it so we never skip incorrectly.
if "$RCLONE" lsf "$REMOTE_PREFIX" --include "UPLOADED.OK" >/dev/null 2>&1; then
  echo "Remote has stale UPLOADED.OK but is incomplete; removing marker and continuing…" | tee -a "$LOG_FILE"
  delete_remote_marker_if_present
fi

# ---------- Build chunk manifests ----------
mkdir -p "$PARTS_DIR" "$PARTS_DIR/sql"

# excludes
declare -a EX_PATTERNS=()
if [[ -n "${EXCLUDES_FILE:-}" && -f "$EXCLUDES_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    EX_PATTERNS+=("$line")
  done < "$EXCLUDES_FILE"
fi
should_exclude() {
  local rel="$1"
  for pat in "${EX_PATTERNS[@]}"; do
    [[ "$rel" == $pat ]] && return 0
  done
  return 1
}

# EXPECTED list (rebuild every run)
: > "$MANIFEST_EXPECTED"
for DB in "${DBS[@]}"; do
  echo "sql/${DB}_${DATE}.sql.gz" >> "$MANIFEST_EXPECTED"
done
while IFS= read -r -d '' abs; do
  rel="${abs#$SOURCE_DIR/}"
  if [[ ${#EX_PATTERNS[@]} -gt 0 ]] && should_exclude "$rel"; then
    continue
  fi
  printf '%s\n' "$rel" >> "$MANIFEST_EXPECTED"
done < <(find "$SOURCE_DIR" \( -type f -o -type l \) -print0)
LC_ALL=C sort -u -o "$MANIFEST_EXPECTED" "$MANIFEST_EXPECTED"
EXPECTED_COUNT="$(wc -l < "$MANIFEST_EXPECTED" | awk '{print $1}')"

# DONE list: re-derive from existing chunks (ensures consistency)
if compgen -G "$PARTS_DIR/${CHUNK_PREFIX}-*.zip" >/dev/null 2>&1; then
  list_archived_entries > "$MANIFEST_DONE"
else
  : > "$MANIFEST_DONE"
fi

# ---------- Create SQL dumps (idempotent) ----------
for DB in "${DBS[@]}"; do
  OUT="${PARTS_DIR}/sql/${DB}_${DATE}.sql.gz"
  if [[ ! -s "$OUT" ]]; then
    echo "Dumping DB: $DB -> $OUT" | tee -a "$LOG_FILE"
    mysqldump "${MYSQL_OPTS[@]}" "$DB" | gzip -c > "$OUT"
  else
    echo "Reusing existing dump: $OUT" | tee -a "$LOG_FILE"
  fi
done

# ---------- Remaining paths to archive ----------
REMAINING_FILE="$WORK_DIR/remaining.txt"
LC_ALL=C comm -23 "$MANIFEST_EXPECTED" "$MANIFEST_DONE" > "$REMAINING_FILE" || true
REMAINING_COUNT="$(wc -l < "$REMAINING_FILE" | awk '{print $1}')"

BUDGET_LEFT_BYTES="$(bytes_from_human_mb "$CHUNK_BUDGET_MB")"
TARGET_CHUNK_BYTES="$(bytes_from_human_mb "$CHUNK_TARGET_MB")"
CREATED_BYTES=0
CREATED_CHUNKS=0

if [[ "$REMAINING_COUNT" -eq 0 ]]; then
  echo "All content already archived in chunks. Proceeding to upload stage…" | tee -a "$LOG_FILE"
else
  echo "Need to archive ${REMAINING_COUNT} paths. Per-run budget: $(human_from_bytes "$BUDGET_LEFT_BYTES")" | tee -a "$LOG_FILE"
fi

# next chunk index
last_idx=0
if compgen -G "$PARTS_DIR/${CHUNK_PREFIX}-*.zip" >/dev/null 2>&1; then
  last_idx="$(ls "$PARTS_DIR"/${CHUNK_PREFIX}-*.zip | sed -E 's/.*-0*([0-9]+)\.zip/\1/' | sort -n | tail -1)"
fi

# ---------- Chunk creation loop (cap by budget) ----------
while [[ "$REMAINING_COUNT" -gt 0 && "$BUDGET_LEFT_BYTES" -gt 0 ]]; do
  idx=$(( last_idx + 1 ))
  chunk="$PARTS_DIR/${CHUNK_PREFIX}-$(printf '%04d' "$idx").zip"
  list="$WORK_DIR/chunk_${idx}.list"
  : > "$list"

  current_chunk_bytes=0

  while IFS= read -r rel || [[ -n "$rel" ]]; do
    # resolve absolute path and size
    if [[ "$rel" == sql/* ]]; then
      abs="$PARTS_DIR/$rel"
    else
      abs="$SOURCE_DIR/$rel"
    fi
    # must exist
    if [[ ! -e "$abs" ]]; then
      echo "NOTE: skipping missing path: $rel" | tee -a "$LOG_FILE"
      continue
    fi
    sz="$(file_size_bytes "$abs")"
    # if adding this would exceed target and we already have something, stop filling this chunk
    if [[ "$current_chunk_bytes" -gt 0 && $(( current_chunk_bytes + sz )) -gt "$TARGET_CHUNK_BYTES" ]]; then
      break
    fi
    printf '%s\n' "$rel" >> "$list"
    current_chunk_bytes=$(( current_chunk_bytes + sz ))
  done < "$REMAINING_FILE"

  if [[ ! -s "$list" ]]; then
    echo "No files to include in this chunk iteration; skipping." | tee -a "$LOG_FILE"
    break
  fi

  echo "Creating chunk: $(basename "$chunk")  (~$(human_from_bytes "$current_chunk_bytes"))" | tee -a "$LOG_FILE"

  # Build zip in two phases to keep relative paths correct
  # 1) SQL files from PARTS_DIR
  tmp_sql_list="$WORK_DIR/chunk_${idx}_sql.list"
  grep '^sql/' "$list" > "$tmp_sql_list" || true
  if [[ -s "$tmp_sql_list" ]]; then
    (cd "$PARTS_DIR" && zip -q -y "$chunk" -@ < "$tmp_sql_list")
  fi
  # 2) Source files from SOURCE_DIR
  tmp_src_list="$WORK_DIR/chunk_${idx}_src.list"
  grep -v '^sql/' "$list" > "$tmp_src_list" || true
  if [[ -s "$tmp_src_list" ]]; then
    (cd "$SOURCE_DIR" && zip -q -y "$chunk" -@ < "$tmp_src_list")
  fi

  # Verify chunk integrity
  if ! zip_test "$chunk"; then
    echo "Chunk failed integrity test: $chunk" | tee -a "$LOG_FILE"
    mv -f "$chunk" "${chunk}.bad.$(date +%s)" 2>/dev/null || true
    STATUS="FAILURE"; ERROR_MSG="Bad chunk: $(basename "$chunk")"; exit 8
  fi

  # Update DONE manifest
  cat "$list" >> "$MANIFEST_DONE"
  LC_ALL=C sort -u -o "$MANIFEST_DONE" "$MANIFEST_DONE"

  # Recompute remaining
  LC_ALL=C comm -23 "$MANIFEST_EXPECTED" "$MANIFEST_DONE" > "$REMAINING_FILE" || true
  REMAINING_COUNT="$(wc -l < "$REMAINING_FILE" | awk '{print $1}')"

  # Account budget by actual compressed size
  zbytes=$(file_size_bytes "$chunk")
  CREATED_BYTES=$(( CREATED_BYTES + zbytes ))
  BUDGET_LEFT_BYTES=$(( BUDGET_LEFT_BYTES - zbytes ))
  CREATED_CHUNKS=$(( CREATED_CHUNKS + 1 ))
  last_idx=$idx

  echo "Created $(basename "$chunk"), size=$(human_from_bytes "$zbytes"); budget left=$(human_from_bytes "$BUDGET_LEFT_BYTES"); remaining files=$REMAINING_COUNT" | tee -a "$LOG_FILE"

  # stop if budget exhausted
  if [[ "$BUDGET_LEFT_BYTES" -le 0 ]]; then
    echo "Per-run budget reached (~$(human_from_bytes "$CREATED_BYTES")). Stopping chunk creation for this run." | tee -a "$LOG_FILE"
    break
  fi
done

# Summarize current archive state
list_archived_entries > "$MANIFEST_ARCHIVED" || : > "$MANIFEST_ARCHIVED"
ARCHIVED_COUNT="$(wc -l < "$MANIFEST_ARCHIVED" | awk '{print $1}')"

# Diffs for email/log
DIFF_MISSING="$WORK_DIR/missing.txt"
DIFF_EXTRA="$WORK_DIR/extra.txt"
LC_ALL=C comm -23 "$MANIFEST_EXPECTED" "$MANIFEST_ARCHIVED" > "$DIFF_MISSING" || true
LC_ALL=C comm -13 "$MANIFEST_EXPECTED" "$MANIFEST_ARCHIVED" > "$DIFF_EXTRA" || true
MISSING_COUNT="$(wc -l < "$DIFF_MISSING" | awk '{print $1}')"
EXTRA_COUNT="$(wc -l < "$DIFF_EXTRA" | awk '{print $1}')"

# Optional verification on reuse
if [[ "$MISSING_COUNT" -gt 0 && "$VERIFY_REUSED_ARCHIVE" -eq 1 ]]; then
  echo "WARNING: Still missing ${MISSING_COUNT} entries (will continue next run)." | tee -a "$LOG_FILE"
fi

# ---------- Upload to B2 (single-threaded, no early marker) ----------
if [[ "$MISSING_COUNT" -eq 0 ]]; then
  echo "All expected content archived across chunks ($ARCHIVED_COUNT entries). Starting upload stage…" | tee -a "$LOG_FILE"

  # Include manifests in the upload (but DO NOT create the marker locally)
  cp -f "$MANIFEST_EXPECTED" "$PARTS_DIR/" || true
  cp -f "$MANIFEST_ARCHIVED" "$PARTS_DIR/" || true

  echo "Uploading to remote: $REMOTE_PREFIX (using $RCLONE)" | tee -a "$LOG_FILE"
  echo "Note: lowering concurrency to avoid Bluehost ulimit issues." | tee -a "$LOG_FILE"

  # Very conservative settings for shared hosting
  "$RCLONE" copy "$PARTS_DIR" "$REMOTE_PREFIX" \
    --transfers=1 --checkers=1 \
    --b2-chunk-size=32M --b2-upload-cutoff=32M \
    --retries=10 --retries-sleep=10s --low-level-retries=20 \
    --buffer-size=32M --bwlimit="$BWLIMIT" \
    --disable-http2 \
    --log-level=INFO --log-file="$LOG_FILE"

  RC_CLONE=$?
  if [[ $RC_CLONE -ne 0 ]]; then
    echo "rclone copy returned non-zero ($RC_CLONE). Will NOT write marker." | tee -a "$LOG_FILE"
    STATUS="FAILURE"; ERROR_MSG="rclone copy failed (exit $RC_CLONE)"
    exit 2
  fi

  # Verify the remote now exactly matches our local parts (size-only catches 0-byte/partial files).
  if remote_is_complete; then
    echo "Remote verification succeeded — writing completion marker." | tee -a "$LOG_FILE"
    write_remote_marker
    UPLOAD_COMPLETED=true
  else
    echo "Remote verification FAILED after upload — not writing marker." | tee -a "$LOG_FILE"
    STATUS="FAILURE"; ERROR_MSG="Remote incomplete after upload"
    exit 5
  fi
else
  echo "Partial archive this run: ${MISSING_COUNT} entries still remaining. Upload skipped; will continue next run." | tee -a "$LOG_FILE"
  SKIPPED_REMOTE=true
fi

# ---------- Retention ----------
echo "Pruning local archives older than ${KEEP_LOCAL_DAYS} days" | tee -a "$LOG_FILE"
# remove any *.parts directories older than threshold (not just current period)
find "$BACKUP_DIR" -maxdepth 1 -type d -name "*.parts" -mtime +$KEEP_LOCAL_DAYS -print -exec rm -rf {} \; >> "$LOG_FILE" 2>&1 || true
find "$BACKUP_DIR" -type f -name "*.bad.*" -mtime +$KEEP_LOCAL_DAYS -print -delete >> "$LOG_FILE" 2>&1 || true

echo "Pruning remote archives older than ${KEEP_REMOTE_DAYS} days" | tee -a "$LOG_FILE"
"$RCLONE" delete "$REMOTE" --min-age "${KEEP_REMOTE_DAYS}d" --include "*/*.zip" --log-level=INFO --log-file="$LOG_FILE" || true
"$RCLONE" rmdirs "$REMOTE" --leave-root --log-level=INFO --log-file="$LOG_FILE" || true

echo "[$(date -Is)] Backup finished for ${BASENAME}" | tee -a "$LOG_FILE"

