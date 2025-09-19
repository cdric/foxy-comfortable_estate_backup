#!/usr/bin/env bash
set -euo pipefail

# Safer defaults for cron environments
export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
umask 077

# ========= USER CONFIG =========
HOME_DIR="/home4/uhdtdbmy"
#SOURCE_DIR="$HOME_DIR/gocozyhomes-backups/b2/testdata"      # directory to back up
SOURCE_DIR="$HOME_DIR/public_html/gocozyhomes"
BACKUP_DIR="$HOME_DIR/gocozyhomes-backups/b2/backups"       # local folder to store zips
REMOTE="b2:cozyhomes-www/backups"                           # rclone remote:bucket/path
KEEP_LOCAL_DAYS=90                                          # days to keep local zips
KEEP_REMOTE_DAYS=3650                                       # days to keep remote zips
EXCLUDES_FILE=""                                            # optional: exclude patterns file (one per line)
BWLIMIT="0"                                                 # rclone bandwidth limit (e.g., "4M"); "0" = unlimited
LOG_FILE="$HOME_DIR/gocozyhomes-backups/b2/logs/backup_rclone.log"  # log file path

# How often to create a new backup: daily | weekly | monthly
BACKUP_FREQUENCY="monthly"

# --- Email (sendmail only) ---
MAIL_TO="gocozyhomes2021@gmail.com"
MAIL_FROM="do-not-reply@gocozyhomes.com"
MAIL_SUBJECT_PREFIX="[Backup GoCozyHomes]"

# --- Database config ---  (use ~/.my.cnf; leave USER/PASS blank)
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
  weekly)  PERIOD_TAG="$(date +'%G-W%V')" ;;   # ISO week (e.g., 2025-W34)
  monthly) PERIOD_TAG="$(date +'%Y-%m')" ;;
  *)       PERIOD_TAG="$(date +'%Y-%m')" ;;
esac

BASENAME="${PERIOD_TAG}"
WORK_DIR="$(mktemp -d /tmp/backup_${PERIOD_TAG}_XXXX)"
SQL_DIR="${WORK_DIR}/sql"
mkdir -p "$SQL_DIR"
ZIP_FILE="${BACKUP_DIR}/${BASENAME}.zip"

STATUS="SUCCESS"
ERROR_MSG=""
ZIP_SIZE=""
SQL_BYTES=0
SQL_SIZE_HUMAN=""
REUSED_ZIP=false
SKIPPED_REMOTE=false

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
    "/usr/local/bin/rclone"
    "/usr/bin/rclone"
  )
  for c in "${candidates[@]}"; do
    if [[ -n "$c" && -x "$c" ]]; then
      echo "$c"; return 0
    fi
  done
  return 1
}
RCLONE="$(find_rclone || true)"

on_error() {
  local exit_code=$?
  STATUS="FAILURE"
  ERROR_MSG="Command failed (exit $exit_code): $BASH_COMMAND"
  # quarantine a bad/incomplete zip to avoid append errors next run
  if [[ -f "$ZIP_FILE" ]]; then
    if command -v unzip >/dev/null 2>&1; then
      if ! unzip -tqq "$ZIP_FILE" >/dev/null 2>&1; then
        mv -f "$ZIP_FILE" "${ZIP_FILE}.bad.$(date +%s)" 2>/dev/null || rm -f "$ZIP_FILE" || true
      fi
    else
      [[ ! -s "$ZIP_FILE" ]] && mv -f "$ZIP_FILE" "${ZIP_FILE}.bad.$(date +%s)" 2>/dev/null || true
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

  [[ -f "$ZIP_FILE" ]] && ZIP_SIZE=$(du -h "$ZIP_FILE" | awk '{print $1}')
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
  remote_note="$REMOTE/$(basename "$ZIP_FILE")"

  local subject="${MAIL_SUBJECT_PREFIX} ${STATUS}$([[ "$SKIPPED_REMOTE" == true ]] && echo ' (ALREADY ON REMOTE)') - ${BASENAME} on ${HOST}"
  read -r -d '' body <<EOF || true
Backup status: ${STATUS}
Host: ${HOST}
Date: ${DATE}
Period: ${BACKUP_FREQUENCY} (${BASENAME})

Source dir: ${SOURCE_DIR}
Local zip: ${ZIP_FILE}
Zip size: ${ZIP_SIZE:-n/a}
Reused existing zip: ${REUSED_ZIP}
Skipped because already on remote: ${SKIPPED_REMOTE}

Databases: ${DBS[*]}
DB dumps (compressed): ${SQL_SIZE_HUMAN:-n/a}

Remote target: ${REMOTE}
Remote file: ${remote_note}

rclone path: ${RCLONE:-not found}
Log file: ${LOG_FILE}
Finished at: ${now}

$( [[ "$STATUS" = "FAILURE" ]] && echo "Error: ${ERROR_MSG}" )

--- Last 60 log lines ---
${log_tail}
EOF

  send_email "$subject" "$body"
  rm -rf "$WORK_DIR"
}
trap finish EXIT

# Prevent overlapping runs
LOCKFILE="/tmp/backup_to_b2.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "Another backup is running; exiting." | tee -a "$LOG_FILE"
  STATUS="FAILURE"; ERROR_MSG="Lockfile in use"
  exit 1
fi

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"
echo "[$(date -Is)] Starting backup for period ${BASENAME}" | tee -a "$LOG_FILE"

# Fail early if rclone missing
if [[ -z "${RCLONE:-}" ]]; then
  echo "ERROR: rclone not found. Install it under \$HOME/bin or set RCLONE_BIN=/full/path/to/rclone" | tee -a "$LOG_FILE"
  STATUS="FAILURE"; ERROR_MSG="rclone not found"
  exit 6
fi

# ---------- MySQL dump options ----------
: "${DB_HOST:=localhost}"
MYSQL_OPTS=(--host="$DB_HOST" --single-transaction --quick --hex-blob)
[[ -n "${DB_USER:-}" ]] && MYSQL_OPTS+=(--user="$DB_USER")
[[ -n "${DB_PASS:-}" ]] && MYSQL_OPTS+=(--password="$DB_PASS")

# ---------- Remote skip check ----------
if "$RCLONE" lsf "$REMOTE" --include "${BASENAME}.zip" --log-level=INFO --log-file="$LOG_FILE" | grep -qx "${BASENAME}.zip"; then
  echo "Backup for ${BASENAME} already exists on remote. Skipping." | tee -a "$LOG_FILE"
  STATUS="SUCCESS"; SKIPPED_REMOTE=true
  exit 0
fi

# ---------- Local reuse check ----------
if [[ -f "$ZIP_FILE" ]]; then
  if command -v unzip >/dev/null 2>&1 && unzip -tqq "$ZIP_FILE" >/dev/null 2>&1; then
    echo "Found valid local archive for ${BASENAME}, reusing: $ZIP_FILE" | tee -a "$LOG_FILE"
    REUSED_ZIP=true
  else
    echo "Local archive invalid. Quarantining and rebuilding." | tee -a "$LOG_FILE"
    mv -f "$ZIP_FILE" "${ZIP_FILE}.bad.$(date +%s)" 2>/dev/null || rm -f "$ZIP_FILE" || true
  fi
fi

# ---------- Only create dumps/zip if NOT reusing ----------
if [[ "$REUSED_ZIP" == false ]]; then
  mkdir -p "$SQL_DIR"

  # Dump DBs (compressed)
  for DB in "${DBS[@]}"; do
    OUT="${SQL_DIR}/${DB}_${DATE}.sql.gz"
    echo "Dumping DB: $DB -> $OUT" | tee -a "$LOG_FILE"
    mysqldump "${MYSQL_OPTS[@]}" "$DB" | gzip -c > "$OUT"
  done

  # Prepare arrays (avoid set -u issues)
  declare -a EX_PATTERNS=()
  declare -a SQL_LIST=()
  declare -a SRC_LIST=()

  # Load exclude patterns
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

  # Helper for file size (GNU/BSD stat)
  filesize() {
    local f="$1"
    if stat -c%s "$f" >/dev/null 2>&1; then stat -c%s "$f"; else stat -f%z "$f"; fi
  }

  # Collect SQL files (absolute paths)
  if compgen -G "$SQL_DIR/*.gz" >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      SQL_LIST+=("$f")
    done < <(find "$SQL_DIR" -type f -name '*.gz' -print0)
  fi

  # Collect source files (build in the parent shell)
  while IFS= read -r -d '' abs; do
    rel="${abs#$SOURCE_DIR/}"
    if [[ ${#EX_PATTERNS[@]} -gt 0 ]] && should_exclude "$rel"; then
      continue
    fi
    SRC_LIST+=("$rel")
  done < <(find "$SOURCE_DIR" -type f -print0)

  # Compute total bytes for progress
  TOTAL_BYTES=0
  for f in "${SQL_LIST[@]}"; do (( TOTAL_BYTES += $(filesize "$f") )); done
  for rel in "${SRC_LIST[@]}"; do (( TOTAL_BYTES += $(filesize "$SOURCE_DIR/$rel") )); done

  # CLI progress
  SHOW_PROGRESS=0; [[ -t 1 ]] && SHOW_PROGRESS=1
  CUM_BYTES=0
  progress() {
    if (( SHOW_PROGRESS )); then
      pct=$(( TOTAL_BYTES > 0 ? (CUM_BYTES * 100 / TOTAL_BYTES) : 100 ))
      printf "\rZipping: %3d%% (%s / %s bytes)" "$pct" "$CUM_BYTES" "$TOTAL_BYTES"
    fi
  }

  # 1) Add SQL dumps under "sql/"
  if [ "${#SQL_LIST[@]}" -gt 0 ]; then
    (
      cd "$WORK_DIR"
      for f in "${SQL_LIST[@]}"; do
        rel_sql="sql/$(basename "$f")"
        zip -9 -q "$ZIP_FILE" "$rel_sql"
        (( CUM_BYTES += $(filesize "$f") ))
        progress
      done
    )
  fi

  # 2) Add site files as relative paths
  (
    cd "$SOURCE_DIR"
    for rel in "${SRC_LIST[@]}"; do
      zip -9 -q "$ZIP_FILE" "$rel"
      (( CUM_BYTES += $(filesize "$SOURCE_DIR/$rel") ))
      progress
    done
  )
  (( SHOW_PROGRESS )) && echo ""

  # Validate the final zip
  if [[ ! -s "$ZIP_FILE" ]]; then
    echo "Zip file is empty or missing: $ZIP_FILE" | tee -a "$LOG_FILE"
    STATUS="FAILURE"; ERROR_MSG="Zip file missing or empty"; exit 4
  fi
  if command -v unzip >/dev/null 2>&1; then
    if ! unzip -tqq "$ZIP_FILE" >/dev/null 2>&1; then
      echo "Zip integrity test failed for $ZIP_FILE" | tee -a "$LOG_FILE"
      STATUS="FAILURE"; ERROR_MSG="Zip integrity test failed"; exit 4
    fi
  fi
else
  echo "Skipping zipping step (reusing ${ZIP_FILE})." | tee -a "$LOG_FILE"
fi

# ---------- Upload to B2 ----------
echo "Uploading to remote: $REMOTE (using $RCLONE)" | tee -a "$LOG_FILE"
"$RCLONE" copy "$ZIP_FILE" "$REMOTE" \
  --transfers=1 --checkers=4 \
  --b2-chunk-size=96M \
  --retries=10 --low-level-retries=20 \
  --buffer-size=64M --bwlimit="$BWLIMIT" \
  --log-level=INFO --log-file="$LOG_FILE"

# Verify uploaded file exists remotely
if ! "$RCLONE" lsf "$REMOTE" --include "${BASENAME}.zip" --log-level=INFO --log-file="$LOG_FILE" | grep -qx "${BASENAME}.zip"; then
  echo "Remote verification failed: file not found after upload." | tee -a "$LOG_FILE"
  STATUS="FAILURE"; ERROR_MSG="Remote verification failed"; exit 5
fi

# ---------- Retention ----------
echo "Pruning local backups older than ${KEEP_LOCAL_DAYS} days" | tee -a "$LOG_FILE"
find "$BACKUP_DIR" -type f -name "*.zip" -mtime +$KEEP_LOCAL_DAYS -print -delete >> "$LOG_FILE" 2>&1 || true

echo "Pruning remote backups older than ${KEEP_REMOTE_DAYS} days" | tee -a "$LOG_FILE"
"$RCLONE" delete "$REMOTE" --min-age "${KEEP_REMOTE_DAYS}d" --include "*.zip" --log-level=INFO --log-file="$LOG_FILE" || true
"$RCLONE" rmdirs "$REMOTE" --leave-root --log-level=INFO --log-file="$LOG_FILE" || true

echo "[$(date -Is)] Backup finished: $ZIP_FILE" | tee -a "$LOG_FILE"

