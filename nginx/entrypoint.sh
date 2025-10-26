#!/bin/sh
set -eu

TEMPLATE=/etc/nginx/nginx.tmpl.conf
DEST=/etc/nginx/nginx.conf

# Map ACTIVE_POOL to primary/backup hosts
case "${ACTIVE_POOL:-blue}" in
  blue)
    PRIMARY_HOST=${BLUE_HOST:-app_blue}
    BACKUP_HOST=${GREEN_HOST:-app_green}
    ;;
  green)
    PRIMARY_HOST=${GREEN_HOST:-app_green}
    BACKUP_HOST=${BLUE_HOST:-app_blue}
    ;;
  *)
    echo "Invalid ACTIVE_POOL=${ACTIVE_POOL}, defaulting to blue"
    PRIMARY_HOST=${BLUE_HOST:-app_blue}
    BACKUP_HOST=${GREEN_HOST:-app_green}
    ;;
esac

APP_PORT=${APP_PORT:-3000}

# Generate nginx.conf by simple replacement
sed "s/__PRIMARY_HOST__/${PRIMARY_HOST}/g; s/__BACKUP_HOST__/${BACKUP_HOST}/g; s/__APP_PORT__/${APP_PORT}/g" "$TEMPLATE" > "$DEST"

# start nginx in foreground
echo "Starting nginx with PRIMARY=${PRIMARY_HOST}:${APP_PORT} BACKUP=${BACKUP_HOST}:${APP_PORT}"
nginx -g 'daemon off;'
