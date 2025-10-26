#!/bin/sh
# Regenerate config from template and reload nginx gracefully.
set -eu

TEMPLATE=/etc/nginx/nginx.tmpl.conf
DEST=/etc/nginx/nginx.conf

# Determine primary/backup same way as entrypoint would
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
    PRIMARY_HOST=${BLUE_HOST:-app_blue}
    BACKUP_HOST=${GREEN_HOST:-app_green}
    ;;
esac

APP_PORT=${APP_PORT:-3000}

sed "s/__PRIMARY_HOST__/${PRIMARY_HOST}/g; s/__BACKUP_HOST__/${BACKUP_HOST}/g; s/__APP_PORT__/${APP_PORT}/g" "$TEMPLATE" > "$DEST"

# reload nginx
nginx -s reload
