#!/bin/sh
# Non-Laravel entrypoint — for apps without `artisan`.
#
# Minimal: ensure writable dirs exist under the bind-mounted storage volume,
# optionally run a custom migrate script, then hand off to supervisord.

set -e

cd /var/www/html

AS_WEB="su-exec www-data"

# Ensure runtime subdirs on the mounted storage volume.
mkdir -p storage/framework/sessions storage/framework/views storage/framework/cache \
         storage/logs storage/uploads
chown -R www-data:www-data storage

# SQLite WAL mode — persistent per-DB setting.
for dbf in storage/database.sqlite database/database.sqlite; do
  [ -f "$dbf" ] && $AS_WEB sqlite3 "$dbf" 'PRAGMA journal_mode=WAL;' >/dev/null 2>&1 || true
done

# Opt-in migrations for custom frameworks with a `migrate` script at repo root.
# Flip AUTO_MIGRATE=true in Coolify env for one deploy, then flip back.
if [ "${AUTO_MIGRATE:-false}" = "true" ] && [ -f migrate ]; then
  $AS_WEB php migrate
fi

exec "$@"
