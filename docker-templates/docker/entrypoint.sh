#!/bin/sh
# Laravel entrypoint — git-deploy variant.
#
# Source is baked into the image at build time. Persistent state (SQLite,
# uploads, logs) comes from the /var/www/html/storage (and optionally
# /var/www/html/database) bind-mount volumes.
#
# For non-Laravel / no-artisan apps, use variants/entrypoint.custom.sh instead.

set -e

cd /var/www/html

AS_WEB="su-exec www-data"

# Ensure runtime subdirs exist on the mounted volumes.
mkdir -p storage/app/public storage/framework/sessions storage/framework/views \
         storage/framework/cache storage/logs database
chown -R www-data:www-data storage database

# SQLite WAL mode — persistent per-DB setting. Improves read concurrency
# during writes (Livewire apps that issue many small reads benefit most).
# No-op if already WAL. Creates sidecar -wal and -shm files — expected.
for dbf in storage/database.sqlite database/database.sqlite; do
  [ -f "$dbf" ] && $AS_WEB sqlite3 "$dbf" 'PRAGMA journal_mode=WAL;' >/dev/null 2>&1 || true
done

# Laravel warmup — cache against the baked-in config/routes/views.
# storage:link is idempotent; only needed if someone wiped public/storage.
$AS_WEB php artisan storage:link 2>/dev/null || true
$AS_WEB php artisan config:cache
$AS_WEB php artisan route:cache  || true
$AS_WEB php artisan view:cache   || true

# Opt-in migrations. Default OFF — flip AUTO_MIGRATE=true in Coolify env for
# one deploy to apply pending migrations, then set it back to false.
if [ "${AUTO_MIGRATE:-false}" = "true" ]; then
  $AS_WEB php artisan migrate --force
fi

# Restart queue workers so they pick up fresh code (harmless if queue is idle).
$AS_WEB php artisan queue:restart 2>/dev/null || true

exec "$@"
