#!/bin/sh
# Per-app artisan wrapper. Drop into the app's bind-mount dir on the VPS
# (e.g. /opt/<client>-apps/<app>/artisan) and chmod +x.
#
# Usage from the app's bind-mount dir:
#   ./artisan <subcommand>      # e.g. ./artisan optimize
#   ./artisan --shell           # interactive shell in the running container
#
# Requires: the calling user is in the docker group (provision-host.sh does
# this when ADD_TO_DOCKER_GROUP=true).
#
# Installation (example — replace the UUID with the Coolify app's resource UUID):
#   sed 's/APP_UUID_HERE/i75wmbv3b6dxp7wffzttfjzu/' artisan-wrapper.sh \
#     > /opt/<client>-apps/<app>/artisan
#   chmod +x /opt/<client>-apps/<app>/artisan
#   chown <client>:<client> /opt/<client>-apps/<app>/artisan
#
# The UUID is visible in Coolify UI (app URL, container name) or via:
#   docker exec -i coolify-db psql -U coolify -d coolify -c \
#     "SELECT uuid, name FROM applications ORDER BY id;"

set -e

APP_UUID="APP_UUID_HERE"

c=$(docker ps --format "{{.Names}}" | grep "$APP_UUID" | head -1)
if [ -z "$c" ]; then
  echo "no running container matching UUID prefix $APP_UUID" >&2
  echo "is the app deployed? check: docker ps | grep $APP_UUID" >&2
  exit 1
fi

if [ "$1" = "--shell" ]; then
  exec docker exec -u www-data -it "$c" sh
fi

exec docker exec -u www-data -it "$c" php artisan "$@"
