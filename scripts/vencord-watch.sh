#!/bin/bash
# Wait until the user launches Discord for the first time
# (~/.config/discord/ gets created), then install Vencord.
# Exits immediately if Vencord was already installed by this script.

set -u

DISCORD_DIR="$HOME/.config/discord"
STATE_DIR="$HOME/.local/state/omochi-shell/vencord"
DONE_FILE="$STATE_DIR/.done"

mkdir -p "$STATE_DIR"
[ -e "$DONE_FILE" ] && exit 0

# Allow only one watcher at a time
exec 9>"$STATE_DIR/.lock"
flock -n 9 || exit 0

# Wait until a path exists, using inotify on its parent directory.
# timeout of 0 means wait forever. Returns 1 on timeout.
# The path is re-checked after every event or 5s wake-up, so a path
# created between the check and the watch start is never missed.
wait_for_path() {
    local target="$1"
    local timeout="$2"
    local parent
    parent=$(dirname "$target")
    local deadline=$(( $(date +%s) + timeout ))

    mkdir -p "$parent"

    while [ ! -e "$target" ]; do
        if [ "$timeout" -gt 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
            return 1
        fi
        # Exit code 2 means timeout, which is expected here
        inotifywait -qq -t 5 -e create -e moved_to "$parent" || true
    done
    return 0
}

wait_for_path "$DISCORD_DIR" 0

# Give Discord time to finish its first-run initialization.
# Continue even if settings.json never shows up.
wait_for_path "$DISCORD_DIR/settings.json" 120 || true
sleep 5

if vencordinstallercli -install -location "$DISCORD_DIR"; then
    touch "$DONE_FILE"
    notify-send "Vencord" "Installed. Please restart Discord." --icon=dialog-information
else
    notify-send "Vencord" "Installation failed. It will be retried on next login." --icon=dialog-error
fi
