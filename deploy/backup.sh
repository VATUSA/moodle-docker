#!/usr/bin/env bash
# Backs up the Moodle database and moodledata into $BACKUP_DIR, then deletes
# backups older than $BACKUP_KEEP_DAYS. Runs against the live site; schedule it
# from the host's crontab, e.g.:
#   15 3 * * * /opt/moodle-docker/deploy/backup.sh >> /var/log/moodle-backup.log 2>&1
set -euo pipefail
umask 077
cd "$(dirname "$0")"

if [[ -f .env ]]; then set -a; source .env; set +a; fi
dest="${BACKUP_DIR:-./backups}"
keep_days="${BACKUP_KEEP_DAYS:-14}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$dest"
chmod 700 "$dest"

echo "$(date -u +%FT%TZ) backing up database"
docker compose exec -T db sh -c \
    'MYSQL_PWD="$(cat /run/secrets/db_root_password)" exec mysqldump -uroot \
        --single-transaction --quick --routines --triggers --no-tablespaces moodle' \
    | gzip > "$dest/moodle-db-$stamp.sql.gz.partial"
mv "$dest/moodle-db-$stamp.sql.gz.partial" "$dest/moodle-db-$stamp.sql.gz"

# Caches, sessions and temp files are rebuilt by Moodle and not worth keeping.
echo "$(date -u +%FT%TZ) backing up moodledata"
docker compose run --rm --no-deps -T --entrypoint tar web \
    -C /var/www/moodledata \
    --exclude=./cache --exclude=./localcache --exclude=./sessions \
    --exclude=./temp --exclude=./trashdir \
    -czf - . > "$dest/moodledata-$stamp.tar.gz.partial"
mv "$dest/moodledata-$stamp.tar.gz.partial" "$dest/moodledata-$stamp.tar.gz"

find "$dest" -maxdepth 1 \( -name 'moodle-db-*.sql.gz' -o -name 'moodledata-*.tar.gz' \) \
    -mtime +"$keep_days" -delete
echo "$(date -u +%FT%TZ) done"
