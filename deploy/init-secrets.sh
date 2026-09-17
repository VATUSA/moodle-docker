#!/usr/bin/env bash
# Creates random passwords in ./secrets for any that don't exist yet.
# smtp_password starts empty; put the SMTP password in it if you use SMTP.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p secrets
chmod 700 secrets
for name in db_password db_root_password moodle_admin_password; do
    if [[ ! -e "secrets/$name" ]]; then
        openssl rand -base64 24 | tr -d '\n/+=' > "secrets/$name"
        echo "created secrets/$name"
    fi
done
[[ -e secrets/smtp_password ]] || : > secrets/smtp_password

# The containers run as non-root users (www-data, mysql), so the files must be
# world-readable; the 0700 directory keeps other host users out.
chmod 644 secrets/*
echo "Moodle admin password: $(<secrets/moodle_admin_password)"
