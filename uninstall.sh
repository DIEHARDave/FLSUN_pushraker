#!/bin/bash
# Removes FLSUN_pushraker and pushraker. Your notification settings
# (pushraker.conf and pushraker.secrets) are kept, so reinstalling picks
# them up again; delete them yourself if you don't need them.

set -e

CONFIG_DIR="${HOME}/printer_data/config"
MOONRAKER_CONF="${CONFIG_DIR}/moonraker.conf"
VENV="${HOME}/moonraker-env"
SERVICE="flsun_pushraker"
SNIPPET="/etc/nginx/snippets/flsun-pushraker.conf"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -ne 0 ] || { echo "run as the pi user, not root" >&2; exit 1; }

msg "Removing the service"
sudo systemctl disable --now "${SERVICE}.service" > /dev/null 2>&1 || true
sudo rm -f "/etc/systemd/system/${SERVICE}.service"
sudo systemctl daemon-reload
ASVC="${HOME}/printer_data/moonraker.asvc"
[ -f "$ASVC" ] && sed -i "/^${SERVICE}\$/d" "$ASVC"

msg "Removing /notifications/ from the web server"
for link in /etc/nginx/sites-enabled/*; do
    site=$(readlink -f "$link")
    [ -f "$site" ] || continue
    sudo sed -i "\|include ${SNIPPET};|d" "$site"
done
sudo rm -f "$SNIPPET"
sudo nginx -t > /dev/null 2>&1 && sudo systemctl reload nginx

msg "Removing pushraker"
if [ -x "${VENV}/bin/python" ]; then
    (cd "$HOME" && "${VENV}/bin/python" -m pushraker uninstall) || true
    "${VENV}/bin/pip" uninstall -y -q pushraker || true
fi

msg "Removing the Moonraker settings"
sed -i '/^\[include flsun_pushraker\.conf\]/d' "$MOONRAKER_CONF"
rm -f "${CONFIG_DIR}/flsun_pushraker.conf"

msg "Restarting Moonraker and Klipper"
sudo systemctl restart moonraker
state=$(curl -s -m 5 "http://127.0.0.1:7125/printer/objects/query?print_stats=state" \
    | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')
case "$state" in
    printing|paused) echo "A print is $state; Klipper drops the pushraker macros at its next restart." ;;
    *) sudo systemctl restart klipper ;;
esac

msg "Done. Delete ~/FLSUN_pushraker to finish."
