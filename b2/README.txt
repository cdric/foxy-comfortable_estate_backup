CozyHomes Backup Script (rclone + Backblaze B2)
==================================================

Overview
--------
This script creates a timestamped ZIP backup of a directory, dumps one or more MySQL/MariaDB
databases (compressed), uploads the archive to Backblaze B2 via rclone, rotates old backups
(locally and remotely), and emails a status report (success/failure).

Test helpers are provided to verify outbound email from your Bluehost shell.

Files (suggested names)
-----------------------
- backup_rclone_vX.sh      # main backup script (place in: /home4/uhdtdbmy/gocozyhomes-backups/b2/)

Prerequisites
-------------
1) Linux shell on Bluehost (bash).
2) Tools: rclone, zip, gzip, mysqldump, flock (usually available by default on shared hosting).
3) Optional mailers for status email (any of the following):
   - /usr/sbin/sendmail or /usr/lib/sendmail (preferred if present)
   - mail or mailx
   - PHP CLI (for PHP mail() fallback)
4) Backblaze B2 bucket + rclone remote configured (example remote: 'b2').
5) MySQL client access. Prefer using ~/.my.cnf for credentials.

Directory Layout
----------------
HOME_DIR: /home4/uhdtdbmy

Expected paths created by you:
- /home4/uhdtdbmy/gocozyhomes-backups/b2/testdata     (SOURCE_DIR - data to back up)
- /home4/uhdtdbmy/gocozyhomes-backups/b2/backups      (BACKUP_DIR - where ZIPs are stored)
- /home4/uhdtdbmy/gocozyhomes-backups/b2/logs         (for backup_rclone.log)

Configuration (inside the script)
---------------------------------
# ========= USER CONFIG =========
HOME_DIR="/home4/uhdtdbmy"
SOURCE_DIR="$HOME_DIR/gocozyhomes-backups/b2/testdata"            # directory to back up
BACKUP_DIR="$HOME_DIR/gocozyhomes-backups/b2/backups"             # local folder to store zips
REMOTE="b2:cozyhomes-www/backups"                                 # rclone remote:bucket/path
KEEP_LOCAL_DAYS=90                                                  # days to keep local zips
KEEP_REMOTE_DAYS=3650                                               # days to keep remote zips
EXCLUDES_FILE=""                                                  # optional file with exclude patterns (one per line)
BWLIMIT="0"                                                       # rclone bandwidth limit (e.g., "4M"); "0" = unlimited
LOG_FILE="$HOME_DIR/gocozyhomes-backups/b2/logs/backup_rclone.log"# log file path

# Email
MAIL_TO="you@your-domain.com"
MAIL_FROM="backup@your-domain.com"       # use an address on a domain you host on Bluehost
MAIL_SUBJECT_PREFIX="[Backup]"

# Database
DB_HOST=""                               # empty -> defaults to localhost
DB_USER=""                               # leave empty to use ~/.my.cnf
DB_PASS=""                               # leave empty to use ~/.my.cnf
DBS=("uhdtdbmy_cozyhomes")               # list of DBs to dump
# =================================

What the script does
--------------------
1) Creates a temp work directory and a 'sql/' subfolder.
2) Dumps each DB in DBS to gzip files 'sql/<db>_<YYYY-MM-DD>.sql.gz' using mysqldump with:
   --single-transaction --quick --hex-blob (safe for InnoDB; consistent, low memory).
   If DB_USER/PASS are empty, mysqldump reads ~/.my.cnf automatically.
3) Creates a ZIP archive named '<YYYY-MM-DD>.zip' in BACKUP_DIR that contains:
   - sql/ (the compressed DB dumps)
   - SOURCE_DIR (your site/app files)
   Optional: excludes patterns from EXCLUDES_FILE.
4) Uploads the ZIP to Backblaze B2 (REMOTE) using rclone, with resumable multipart uploads.
5) Verifies the uploaded file exists on REMOTE.
6) Prunes local backups older than KEEP_LOCAL_DAYS.
7) Prunes remote backups older than KEEP_REMOTE_DAYS (using rclone delete --min-age).
8) Sends an email with SUCCESS or FAILURE and the last 60 log lines.
9) Cleans up temp directories.

Email Behavior
--------------
- Tries /usr/sbin/sendmail or /usr/lib/sendmail first.
- Falls back to 'mail' or 'mailx' if available.
- Falls back to PHP CLI 'mail()' using '-fMAIL_FROM' as envelope sender.
- If none are available, it writes the email content into the log file.

On Bluehost, use MAIL_FROM as an address on a domain you host there (e.g., backup@your-domain.com).
Create that mailbox or forwarder in the Bluehost panel to improve deliverability, and ensure SPF/DKIM.
If outbound email is blocked or unreliable, consider switching to an SMTP or HTTP API (e.g. Mailgun).

Security Notes
--------------
- Prefer ~/.my.cnf for DB credentials:
  File: /home4/uhdtdbmy/.my.cnf
  Permissions: chmod 600 ~/.my.cnf
  Contents:
    [client]
    user=YOUR_DB_USER
    password=YOUR_DB_PASSWORD
    host=localhost

- Keep your B2 bucket private. Consider using an rclone 'crypt' remote for encryption at rest.
- Logs may include paths and file names; avoid printing secrets.

Retention Policy
----------------
- Local: files older than KEEP_LOCAL_DAYS are deleted from BACKUP_DIR.
- Remote: files older than KEEP_REMOTE_DAYS are deleted from REMOTE path with:
  rclone delete --min-age <KEEP_REMOTE_DAYS>d --include "*.zip"
- Adjust the values to match your compliance/retention needs.

Testing & First Run
-------------------
1) Ensure the directories exist:
   mkdir -p \     /home4/uhdtdbmy/gocozyhomes-backups/b2/backups \     /home4/uhdtdbmy/gocozyhomes-backups/b2/logs

2) Make the script executable:
   chmod +x /home4/uhdtdbmy/gocozyhomes-backups/b2/backup_rclone_v2.sh

3) Test rclone connectivity:
   rclone lsd b2:
   rclone lsd b2:cozyhomes-www

4) (Optional) Test email:
   - Run: ./test_mail.sh   (edit MAIL_TO/MAIL_FROM inside first)

5) Dry run backup:
   /home4/uhdtdbmy/gocozyhomes-backups/b2/backup_rclone_v2.sh

6) Check logs:
   tail -n 200 /home4/uhdtdbmy/gocozyhomes-backups/b2/logs/backup_rclone.log

Cron Setup
----------
Example: run daily at 02:07 (server time):
  7 2 * * * /home4/uhdtdbmy/gocozyhomes-backups/b2/backup_rclone_v2.sh

Bandwidth Throttling
--------------------
If needed, set BWLIMIT to limit upload bandwidth (e.g., BWLIMIT="4M").

Excludes (optional)
-------------------
Create a text file with patterns to skip during ZIP creation and point EXCLUDES_FILE to it.
Example patterns:
  */cache/*
  */tmp/*
  */node_modules/*
  *.log
  *.tmp

Restoring a Backup
------------------
1) List backups on B2:
   rclone ls b2:cozyhomes-www/backups

2) Download the wanted ZIP:
   rclone copy b2:cozyhomes-www/backups/2025-08-21.zip /path/to/restore/

3) Unzip files:
   unzip /path/to/restore/2025-08-21.zip -d /path/to/restore/

4) Restore DB(s):
   gunzip -c /path/to/restore/sql/uhdtdbmy_cozyhomes_2025-08-21.sql.gz | mysql uhdtdbmy_cozyhomes

Troubleshooting
---------------
- 'command not found': make sure rclone/zip/mysqldump are installed and in PATH on Bluehost.
- Email not sending: try test_mail.sh; ensure MAIL_FROM is a local domain; check spam; consider API-based mail.
- rclone upload retries: tune --retries/--low-level-retries/--b2-chunk-size.
- Permission denied: ensure directories exist and are writable by your user.
- Lockfile in use: the prior run may still be running; check for long uploads or stale lock at /tmp/backup_to_b2.lock.

Version
-------
This README covers backup_rclone_v2.sh as last provided on 2025-08-21.
