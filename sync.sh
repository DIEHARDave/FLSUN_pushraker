#!/bin/bash
# Keeps pushraker installed at the version in requirements.txt, with its
# settings page served at http://<printer-ip>/notifications/.
#
# Runs as root: from install.sh, at boot, and when Moonraker restarts the
# flsun_pushraker service after updating this repo. Safe to run any time;
# it only restarts what changed (Klipper only when no print is running).
#
#   --restart-moonraker   restart Moonraker even if nothing here changed
#                         (install.sh: Moonraker has a new update entry)

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="pi"
HOME_DIR="/home/${USER_NAME}"
VENV="${HOME_DIR}/moonraker-env"
PY="${VENV}/bin/python"
SNIPPET="/etc/nginx/snippets/flsun-pushraker.conf"
MOONRAKER_URL="http://127.0.0.1:7125"
NAME="FLSUN T1 Pro"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
as_user() { runuser -u "$USER_NAME" -- "$@"; }

[ "$(id -u)" -eq 0 ] || die "run as root (install.sh does this for you)"
[ -x "$PY" ] || die "Moonraker's Python not found at $PY"
"$PY" -c 'import sys; sys.exit(sys.version_info < (3, 9))' \
    || die "pushraker needs Python 3.9 or newer; FLSun's Moonraker has 3.7. Install FLSUN_moonraker first (https://github.com/DIEHARDave/FLSUN_moonraker)."

# Moonraker's JSON API, read with the system Python.
query() {
    curl -s -m 5 "${MOONRAKER_URL}$1" | python3 -c "$2" 2> /dev/null || true
}
print_state() {
    query "/printer/objects/query?print_stats=state" \
        'import sys, json; print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])'
}
# After an update, Moonraker restarts this service and then finishes its
# own bookkeeping; restarting Moonraker before then would cut it off.
wait_update_manager() {
    for _ in $(seq 60); do
        busy=$(query "/machine/update/status" \
            'import sys, json; print(json.load(sys.stdin)["result"].get("busy", False))')
        [ "$busy" = "True" ] || return 0
        sleep 2
    done
}

restart_moonraker=0
restart_klipper=0
for arg in "$@"; do
    case "$arg" in
        --restart-moonraker) restart_moonraker=1 ;;
        *) die "unknown option: $arg" ;;
    esac
done

want=$(sed -n 's/^pushraker==\([^[:space:]]*\).*/\1/p' "${REPO_DIR}/requirements.txt")
have=$(as_user "$PY" -c 'import importlib.metadata as m; print(m.version("pushraker"))' 2> /dev/null || true)
if [ "$have" != "$want" ]; then
    msg "Installing pushraker ${want}${have:+ (was ${have})}"
    as_user "${VENV}/bin/pip" install --disable-pip-version-check -q \
        -r "${REPO_DIR}/requirements.txt"
    restart_moonraker=1
fi

msg "Setting up pushraker"
# The component, [pushraker] in moonraker.conf, and the Klipper macros
# (pushraker.cfg, included from printer.cfg; FLSUN_klipper copies the
# include for upstream Klipper). Only writes what differs.
out=$(cd "$HOME_DIR" && as_user "$PY" -m pushraker install --name "$NAME")
echo "$out"
if echo "$out" | grep -q '^Updated: .*\(components/\|moonraker\.conf\|\[pushraker\]\|push_notifications\)'; then
    restart_moonraker=1
fi
if echo "$out" | grep -q '^Updated: .*\.cfg$'; then
    restart_klipper=1
fi

msg "Linking the Discord card component"
# FLSUN_notify's card layout for pushraker's Discord messages
# (component/flsun_pushraker.py; [flsun_pushraker] discord_cards).
COMPONENT="${HOME_DIR}/moonraker/moonraker/components/flsun_pushraker.py"
if [ "$(readlink "$COMPONENT" 2> /dev/null)" != "${REPO_DIR}/component/flsun_pushraker.py" ]; then
    as_user ln -sfn "${REPO_DIR}/component/flsun_pushraker.py" "$COMPONENT"
    restart_moonraker=1
fi
CONF="${HOME_DIR}/printer_data/config/flsun_pushraker.conf"
if [ -f "$CONF" ] && ! grep -q '^\[flsun_pushraker\]' "$CONF"; then
    printf '\n%s\n' "$(sed -n '/^\[flsun_pushraker\]/,$p' "${REPO_DIR}/config/flsun_pushraker.conf")" >> "$CONF"
    restart_moonraker=1
fi
# An update changes the component's code, but Moonraker only restarts
# this service; it loads the new code when restarted.
STAMP="${HOME_DIR}/printer_data/.flsun_pushraker_component"
sum=$(sha256sum "${REPO_DIR}/component/flsun_pushraker.py" | cut -d' ' -f1)
if [ "$(cat "$STAMP" 2> /dev/null)" != "$sum" ]; then
    restart_moonraker=1
fi

WEB=$(as_user "$PY" -c 'import os, pushraker; print(os.path.join(os.path.dirname(pushraker.__file__), "web"))')
if [ "$(python3 -I "${REPO_DIR}/tools/fix_page.py" "${WEB}/index.html")" = "fixed" ]; then
    msg "Fixed the settings page's Save and Send Test (Filament change row)"
fi

msg "Serving the settings page at /notifications/"
mkdir -p /etc/nginx/snippets
snippet_text="# FLSUN_pushraker: pushraker's settings page. Written by sync.sh.
location /notifications/ {
    alias ${WEB}/;
    index index.html;
}"
reload_nginx=0
if [ "$(cat "$SNIPPET" 2> /dev/null)" != "$snippet_text" ]; then
    printf '%s\n' "$snippet_text" > "$SNIPPET"
    reload_nginx=1
fi
backups=()
for link in /etc/nginx/sites-enabled/*; do
    site=$(readlink -f "$link")
    [ -f "$site" ] || continue
    grep -q 'server_name' "$site" || continue
    # FLSUN_Updater's Fluidd site includes flsun-pushraker*.conf already.
    grep -qF 'flsun-pushraker' "$site" && continue
    cp "$site" "${site}.flsun_pushraker.bak"
    backups+=("$site")
    # One server block per site (Mainsail's, Fluidd's); add it inside.
    sed -i "0,/^\([[:space:]]*\)server_name .*;/s||&\n\1include ${SNIPPET};|" "$site"
    reload_nginx=1
done
if [ "$reload_nginx" = 1 ]; then
    if ! nginx -t > /dev/null 2>&1; then
        for site in "${backups[@]}"; do
            mv "${site}.flsun_pushraker.bak" "$site"
        done
        nginx -t || true
        die "nginx rejected the configuration; your sites were restored"
    fi
    for site in "${backups[@]}"; do
        rm -f "${site}.flsun_pushraker.bak"
    done
    systemctl reload nginx
fi

if [ "$restart_moonraker" = 1 ]; then
    wait_update_manager
    msg "Restarting Moonraker"
    systemctl restart moonraker
    # Klipper's state comes from Moonraker; give it time to connect.
    for _ in $(seq 30); do
        curl -sf -m 2 "${MOONRAKER_URL}/server/info" > /dev/null && break
        sleep 2
    done
    sleep 5
fi
# Moonraker runs this version of the component now
printf '%s\n' "$sum" > "$STAMP"
if [ "$restart_klipper" = 1 ]; then
    state=$(print_state)
    case "$state" in
        printing|paused)
            warn "a print is ${state}; the pushraker macros load at Klipper's next restart" ;;
        *)
            msg "Restarting Klipper"
            # A service restart, not RESTART: FLSUN_klipper copies printer.cfg's
            # includes for upstream Klipper when the service starts.
            systemctl restart klipper ;;
    esac
fi
msg "pushraker $(as_user "$PY" -c 'import pushraker; print(pushraker.__version__)') is ready: http://<printer-ip>/notifications/"
