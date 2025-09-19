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

# Verify even when reusing a local archive from a prior run this period (0=no,1=yes)
VERIFY_REUSED_ARCHIVE=1
# Limit how many differing paths to print in logs/email (to avoid huge emails)
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

#BASENAME="${PERIOD_TAG}"

## --- NEW: make a unique prefix from SOURCE_DIR path
# Example: /home4/user/public_html/gocozyhomes -> home4_user_public_html_gocozyhomes_<hash8>
PREFIX_RAW="${SOURCE_DIR%/}"
PREFIX_SAFE="$(printf '%s' "${PREFIX_RAW#/}" | tr '/ ' '__' | tr -cs 'A-Za-z0-9._-' '_' )"
# Hash for uniqueness (prefer sha1sum; fallback to shasum/md5sum; final fallback 'nohash')
PREFIX_HASH="$(printf '%s' "$PREFIX_RAW" | { sha1sum 2>/dev/null || shasum 2>/dev/null || md5sum 2>/dev/null; } | awk '{print substr($1,1,8)}')"
[[ -z "$PREFIX_HASH" ]] && PREFIX_HASH="nohash"
UNIQUE_PREFIX="${PREFIX_SAFE}_${PREFIX_HASH}"

# Use the prefix in the base filename for this period
BASENAME="${UNIQUE_PREFIX}_${PERIOD_TAG}"

WORK_DIR="$(mktemp -d /tmp/backup_${PERIOD_TAG}_XXXX)"
SQL_DIR="${WORK_DIR}/sql"
mkdir -p "$SQL_DIR" "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

ARCHIVE_FILE="${BACKUP_DIR}/${BASENAME}.tar.gz"
MANIFEST_EXPECTED="${BACKUP_DIR}/${BASENAME}.manifest.txt"
MANIFEST_ARCHIVED="${BACKUP_DIR}/${BASENAME}.archived.txt"

STATUS="SUCCESS"
ERROR_MSG=""
ARCHIVE_SIZE=""
SQL_BYTES=0
SQL_SIZE_HUMAN=""
REUSED_ARCHIVE=false
SKIPPED_REMOTE=false
EXPECTED_COUNT=""
ARCHIVED_COUNT=""
MISSING_COUNT=""
EXTRA_COUNT=""

# ---------- Email helper (sendmail only) ----------
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

# ---------- Locate rclone (allow override with RCLONE_BIN) ----------
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
  # quarantine a bad/incomplete archive to avoid reuse
  if [[ -f "$ARCHIVE_FILE" ]]; then
    if ! tar -tzf "$ARCHIVE_FILE" >/dev/null 2>&1; then
      mv -f "$ARCHIVE_FILE" "${ARCHIVE_FILE}.bad.$(date +%s)" 2>/dev/null || rm -f "$ARCHIVE_FILE" || true
    fi
  fi
  return $exit_code
}
trap on_error ERR

finish() {
  local end_ts duration_s duration_hms log_tail now remote_note
  end_ts=$(date +%s)
  duration_s=$(( end_ts - START_TS ))
  duration_hms=$(printf "%02d:%02d:%02d" $((duration_s/3600)) $(((duration_s%3600)/60)) $((duration_s%60)))

  [[ -f "$ARCHIVE_FILE" ]] && ARCHIVE_SIZE=$(du -h "$ARCHIVE_FILE" | awk '{print $1}')
  if compgen -G "$SQL_DIR/*.gz" >/dev/null 2>&1; then
    SQL_BYTES=$(du -cb "$SQL_DIR"/*.gz | tail -1 | awk '{print $1}')
    if   [[ "$SQL_BYTES" -lt 1024 ]]; then SQL_SIZE_HUMAN="${SQL_BYTES}B"
    elif [[ "$SQL_BYTES" -lt 1048576 ]]; then SQL_SIZE_HUMAN="$((SQL_BYTES/1024))K"
    elif [[ "$SQL_BYTES" -lt 1073741824 ]]; then SQL_SIZE_HUMAN="$((SQL_BYTES/1048576))M"
    else SQL_SIZE_HUMAN="$(awk -v b="$SQL_BYTES" 'BEGIN{printf "%.1fG", b/1073741824}')"
    fi
  fi

  now="$(date -Is)"
  log_tail="$(tail -n 60 "$LOG_FILE" 2>/dev/null || true)"
  remote_note="$REMOTE/$(basename "$ARCHIVE_FILE")"

  local subject="${MAIL_SUBJECT_PREFIX} ${STATUS}$([[ "$SKIPPED_REMOTE" == true ]] && echo ' (ALREADY ON REMOTE)') - ${BASENAME} on ${HOST}"
  read -r -d '' body <<EOF || true
Backup status: ${STATUS}
Host: ${HOST}
Date: ${DATE}
Period: ${BACKUP_FREQUENCY} (${BASENAME})

Source dir: ${SOURCE_DIR}
Archive: ${ARCHIVE_FILE}
Archive size: ${ARCHIVE_SIZE:-n/a}
Reused existing archive: ${REUSED_ARCHIVE}
Skipped because already on remote: ${SKIPPED_REMOTE}

Verify counts — expected: ${EXPECTED_COUNT:-n/a}, archived: ${ARCHIVED_COUNT:-n/a}, missing: ${MISSING_COUNT:-0}, extra: ${EXTRA_COUNT:-0}

Databases: ${DBS[*]}
DB dumps (compressed): ${SQL_SIZE_HUMAN:-n/a}

Remote target: ${REMOTE}
Remote file: ${remote_note}

rclone path: ${RCLONE:-not found}
Log file: ${LOG_FILE}
Finished at: ${now}
Duration: ${duration_hms}

$( [[ "$STATUS" = "FAILURE" ]] && echo "Error: ${ERROR_MSG}" )

--- Last 60 log lines ---
${log_tail}
EOF

  send_email "$subject" "$body"
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

# ---------- Remote skip check ----------
if "$RCLONE" lsf "$REMOTE" --include "${BASENAME}.tar.gz" --log-level=INFO --log-file="$LOG_FILE" | grep -qx "${BASENAME}.tar.gz"; then
  echo "Backup for ${BASENAME} already exists on remote. Skipping." | tee -a "$LOG_FILE"
  STATUS="SUCCESS"; SKIPPED_REMOTE=true
  exit 0
fi

# ---------- Local reuse check ----------
if [[ -f "$ARCHIVE_FILE" ]]; then
  if tar -tzf "$ARCHIVE_FILE" >/dev/null 2>&1; then
    echo "Found valid local archive for ${BASENAME}, reusing: $ARCHIVE_FILE" | tee -a "$LOG_FILE"
    REUSED_ARCHIVE=true
  else
    echo "Local archive invalid. Quarantining and rebuilding." | tee -a "$LOG_FILE"
    mv -f "$ARCHIVE_FILE" "${ARCHIVE_FILE}.bad.$(date +%s)" 2>/dev/null || rm -f "$ARCHIVE_FILE" || true
  fi
fi

# ---------- Build manifest of EXPECTED entries ----------
# (We always build it — used for verification after creating or when VERIFY_REUSED_ARCHIVE=1)
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

# Start with SQL dumps (as they appear inside the archive under "sql/")
: > "$MANIFEST_EXPECTED"
for DB in "${DBS[@]}"; do
  echo "sql/${DB}_${DATE}.sql.gz" >> "$MANIFEST_EXPECTED"
done

# Add SOURCE_DIR files (regular files + symlinks), relative to SOURCE_DIR and honoring excludes
while IFS= read -r -d '' abs; do
  rel="${abs#$SOURCE_DIR/}"
  if [[ ${#EX_PATTERNS[@]} -gt 0 ]] && should_exclude "$rel"; then
    continue
  fi
  printf '%s\n' "$rel" >> "$MANIFEST_EXPECTED"
done < <(find "$SOURCE_DIR" \( -type f -o -type l \) -print0)

# Normalize & sort manifest (strip duplicate lines just in case)
LC_ALL=C sort -u -o "$MANIFEST_EXPECTED" "$MANIFEST_EXPECTED"
EXPECTED_COUNT="$(wc -l < "$MANIFEST_EXPECTED" | awk '{print $1}')"

# ---------- Only build archive if NOT reusing ----------
if [[ "$REUSED_ARCHIVE" == false ]]; then
  # Dump DBs (compressed) to match manifest entries
  mkdir -p "$SQL_DIR"
  for DB in "${DBS[@]}"; do
    OUT="${SQL_DIR}/${DB}_${DATE}.sql.gz"
    echo "Dumping DB: $DB -> $OUT" | tee -a "$LOG_FILE"
    mysqldump "${MYSQL_OPTS[@]}" "$DB" | gzip -c > "$OUT"
  done

  # tar options (progress when interactive)
  TAR_OPTS=(-czf "$ARCHIVE_FILE" --hard-dereference --warning=no-file-changed)
  [[ -n "${EXCLUDES_FILE:-}" && -f "$EXCLUDES_FILE" ]] && TAR_OPTS+=(--exclude-from="$EXCLUDES_FILE")
  [[ -t 1 ]] && TAR_OPTS+=(--checkpoint=2000 --checkpoint-action=ttyout='.')

  echo "Creating archive: $ARCHIVE_FILE" | tee -a "$LOG_FILE"
  tar "${TAR_OPTS[@]}" -C "$WORK_DIR" sql -C "$SOURCE_DIR" .
  [[ -t 1 ]] && echo ""

  # Validate archive structure
  if [[ ! -s "$ARCHIVE_FILE" ]]; then
    echo "Archive is empty or missing: $ARCHIVE_FILE" | tee -a "$LOG_FILE"
    STATUS="FAILURE"; ERROR_MSG="Archive missing or empty"; exit 4
  fi
  if ! tar -tzf "$ARCHIVE_FILE" >/dev/null 2>&1; then
    echo "Archive integrity test failed: $ARCHIVE_FILE" | tee -a "$LOG_FILE"
    STATUS="FAILURE"; ERROR_MSG="Archive integrity test failed"; exit 4
  fi
else
  echo "Skipping archive build (reusing ${ARCHIVE_FILE})." | tee -a "$LOG_FILE"
fi

# ---------- Build ARCHIVED manifest and compare ----------
# Always build archived listing; enforce on new builds, optional on reuse.
tar -tzf "$ARCHIVE_FILE" | sed -e 's#^./##' -e '/\/$/d' | LC_ALL=C sort -u > "$MANIFEST_ARCHIVED" || {
  echo "Failed to list archive contents" | tee -a "$LOG_FILE"
  STATUS="FAILURE"; ERROR_MSG="Failed to list archive contents"; exit 4
}
ARCHIVED_COUNT="$(wc -l < "$MANIFEST_ARCHIVED" | awk '{print $1}')"

verify_now=true
if [[ "$REUSED_ARCHIVE" == true && "$VERIFY_REUSED_ARCHIVE" -ne 1 ]]; then
  verify_now=false
fi

if $verify_now; then
  # missing = expected - archived
  MISSING_FILE="${WORK_DIR}/missing.txt"
  EXTRA_FILE="${WORK_DIR}/extra.txt"
  LC_ALL=C comm -23 "$MANIFEST_EXPECTED" "$MANIFEST_ARCHIVED" > "$MISSING_FILE" || true
  LC_ALL=C comm -13 "$MANIFEST_EXPECTED" "$MANIFEST_ARCHIVED" > "$EXTRA_FILE" || true

  MISSING_COUNT="$(wc -l < "$MISSING_FILE" | awk '{print $1}')"
  EXTRA_COUNT="$(wc -l < "$EXTRA_FILE" | awk '{print $1}')"

  if [[ "$MISSING_COUNT" -gt 0 ]]; then
    echo "ERROR: ${MISSING_COUNT} expected paths are missing from the archive." | tee -a "$LOG_FILE"
    echo "--- Sample of missing (up to $MAX_DIFF_LINES) ---" | tee -a "$LOG_FILE"
    head -n "$MAX_DIFF_LINES" "$MISSING_FILE" | tee -a "$LOG_FILE"
    STATUS="FAILURE"; ERROR_MSG="Archive missing ${MISSING_COUNT} expected paths"
    exit 7
  fi

  # Not fatal, but log extras (symlinks, etc.)
  if [[ "$EXTRA_COUNT" -gt 0 ]]; then
    echo "Note: ${EXTRA_COUNT} extra paths present in archive (not in manifest). Example:" | tee -a "$LOG_FILE"
    head -n "$MAX_DIFF_LINES" "$EXTRA_FILE" | tee -a "$LOG_FILE"
  fi
else
  echo "Verification skipped for reused archive (set VERIFY_REUSED_ARCHIVE=1 to enforce)." | tee -a "$LOG_FILE"
fi

# ---------- Upload to B2 ----------
echo "Uploading to remote: $REMOTE (using $RCLONE)" | tee -a "$LOG_FILE"
"$RCLONE" copy "$ARCHIVE_FILE" "$REMOTE" \
  --transfers=1 --checkers=4 \
  --b2-chunk-size=96M \
  --retries=10 --low-level-retries=20 \
  --buffer-size=64M --bwlimit="$BWLIMIT" \
  --log-level=INFO --log-file="$LOG_FILE"

# Verify uploaded file exists remotely
if ! "$RCLONE" lsf "$REMOTE" --include "${BASENAME}.tar.gz" --log-level=INFO --log-file="$LOG_FILE" | grep -qx "${BASENAME}.tar.gz"; then
  echo "Remote verification failed: file not found after upload." | tee -a "$LOG_FILE"
  STATUS="FAILURE"; ERROR_MSG="Remote verification failed"; exit 5
fi

# ---------- Retention ----------
echo "Pruning local archives older than ${KEEP_LOCAL_DAYS} days" | tee -a "$LOG_FILE"
find "$BACKUP_DIR" -type f \( -name "*.tar.gz" -o -name "*.manifest.txt" -o -name "*.archived.txt" \) -mtime +$KEEP_LOCAL_DAYS -print -delete >> "$LOG_FILE" 2>&1 || true

echo "Pruning remote archives older than ${KEEP_REMOTE_DAYS} days" | tee -a "$LOG_FILE"
"$RCLONE" delete "$REMOTE" --min-age "${KEEP_REMOTE_DAYS}d" --include "*.tar.gz" --log-level=INFO --log-file="$LOG_FILE" || true
"$RCLONE" rmdirs "$REMOTE" --leave-root --log-level=INFO --log-file="$LOG_FILE" || true

echo "[$(date -Is)] Backup finished: $ARCHIVE_FILE" | tee -a "$LOG_FILE"

