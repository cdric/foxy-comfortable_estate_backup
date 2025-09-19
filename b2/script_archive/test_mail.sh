#!/usr/bin/env bash
set -euo pipefail

MAIL_TO="gocozyhomes2021@gmail.com"      # <-- change me
MAIL_FROM="backup@gocozyhomes.com" # <-- change me (use your domain)
SUBJECT="Mail test $(date -Is)"
BODY="Hello! This is a simple outbound mail test from $(hostname) at $(date -Is)."

ok=false

try_sendmail_abs() {
  local sm=""
  if [[ -x /usr/sbin/sendmail ]]; then sm="/usr/sbin/sendmail"
  elif [[ -x /usr/lib/sendmail ]]; then sm="/usr/lib/sendmail"
  else return 1
  fi

  {
    printf "To: %s\n" "$MAIL_TO"
    printf "From: %s\n" "$MAIL_FROM"
    printf "Subject: %s\n" "$SUBJECT"
    printf "Content-Type: text/plain; charset=UTF-8\n\n"
    printf "%s\n" "$BODY"
  } | "$sm" -t
}

try_mail_cmd() {
  if command -v mail >/dev/null 2>&1; then
    printf "%s\n" "$BODY" | mail -s "$SUBJECT" -r "$MAIL_FROM" "$MAIL_TO"
  elif command -v mailx >/dev/null 2>&1; then
    printf "%s\n" "$BODY" | mailx -s "$SUBJECT" -r "$MAIL_FROM" "$MAIL_TO"
  else
    return 1
  fi
}

try_php_cli() {
  if ! command -v php >/dev/null 2>&1; then
    return 1
  fi
  local tmp_php tmp_msg
  tmp_php="$(mktemp /tmp/mail_XXXX.php)"
  tmp_msg="$(mktemp /tmp/mail_XXXX.txt)"
  printf "%s\n" "$BODY" > "$tmp_msg"
  cat > "$tmp_php" <<PHP
<?php
\$to = '${MAIL_TO}';
\$subject = '${SUBJECT}';
\$headers = "From: ${MAIL_FROM}\\r\\nContent-Type: text/plain; charset=UTF-8\\r\\n";
\$body = file_get_contents('${tmp_msg}');
\$ok = mail(\$to, \$subject, \$body, \$headers, "-f${MAIL_FROM}");
echo \$ok ? "PHP mail() sent\\n" : "PHP mail() failed\\n";
PHP
  php "$tmp_php"
  rm -f "$tmp_php" "$tmp_msg"
}

echo "== Testing absolute sendmail =="
if try_sendmail_abs; then
  echo "OK: sendmail (absolute path) worked"
  ok=true
else
  echo "Not available or failed."
fi

echo "== Testing mail/mailx =="
if try_mail_cmd; then
  echo "OK: mail/mailx worked"
  ok=true
else
  echo "Not available or failed."
fi

echo "== Testing PHP CLI mail() =="
if try_php_cli; then
  echo "Attempted PHP mail()"
  ok=true
else
  echo "PHP not available or failed."
fi

if $ok; then
  echo "✅ At least one method attempted to send. Check your inbox (and spam)."
  exit 0
else
  echo "❌ No mail method available or all attempts failed."
  exit 1
fi

