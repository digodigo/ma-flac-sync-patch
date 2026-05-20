#!/usr/bin/env bash
#
# apply-patch.sh — patch the running Music Assistant Docker container
# so grouped slimproto sync sends MP3 (instead of the hardcoded FLAC)
# to classic Logitech Squeezeboxes.
#
# Run on the Docker host (the box where `docker ps` shows the
# `music-assistant` container). No SSH detour needed.
#
# Usage:
#   ./apply-patch.sh                # apply, then restart container
#   ./apply-patch.sh --no-restart   # apply only
#   ./apply-patch.sh --revert       # restore previous .bak.* and restart
#   CONTAINER=my-mass ./apply-patch.sh   # override default container name
#
# After every MA image update the patch must be re-applied (the install
# overwrites the file). That's why this script exists.

set -euo pipefail

CONTAINER="${CONTAINER:-music-assistant}"
TARGET="/app/venv/lib/python3.13/site-packages/music_assistant/providers/squeezelite/player.py"

# Detect docker binary (Synology has it under /usr/local/bin)
DOCKER="${DOCKER:-$(command -v docker || true)}"
if [ -z "$DOCKER" ] && [ -x /usr/local/bin/docker ]; then
    DOCKER=/usr/local/bin/docker
fi
if [ -z "$DOCKER" ]; then
    echo "ERROR: docker binary not found in PATH" >&2
    exit 1
fi

# Sanity: container exists and is running
if ! "$DOCKER" inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    echo "ERROR: container '$CONTAINER' is not running" >&2
    exit 1
fi

revert() {
    local latest_bak
    latest_bak="$("$DOCKER" exec "$CONTAINER" sh -c "ls -t ${TARGET}.bak.* 2>/dev/null | head -1")"
    if [ -z "$latest_bak" ]; then
        echo "ERROR: no backup file found inside container" >&2
        exit 1
    fi
    echo ">> Restoring from $latest_bak"
    "$DOCKER" exec "$CONTAINER" sh -c "cp '$latest_bak' '$TARGET'"
    echo ">> Restoring done"
}

apply() {
    # Make sure the line we expect is actually there (don't blindly sed)
    if ! "$DOCKER" exec "$CONTAINER" grep -q 'fmt=flac' "$TARGET"; then
        if "$DOCKER" exec "$CONTAINER" grep -q 'fmt=mp3' "$TARGET"; then
            echo ">> Already patched (found fmt=mp3, no fmt=flac). Nothing to do."
            return 0
        fi
        echo "ERROR: neither 'fmt=flac' nor 'fmt=mp3' found in $TARGET — has the MA codebase changed?" >&2
        echo "       Check the file manually:  $DOCKER exec $CONTAINER grep -n 'fmt=' $TARGET" >&2
        exit 1
    fi

    local stamp
    stamp=$(date +%Y%m%d_%H%M%S)
    echo ">> Backing up to ${TARGET}.bak.${stamp}"
    "$DOCKER" exec "$CONTAINER" cp "$TARGET" "${TARGET}.bak.${stamp}"

    echo ">> Patching fmt=flac → fmt=mp3"
    "$DOCKER" exec "$CONTAINER" sed -i 's|fmt=flac|fmt=mp3|g' "$TARGET"

    echo ">> Verifying"
    "$DOCKER" exec "$CONTAINER" grep -n 'fmt=' "$TARGET"
}

restart() {
    echo ">> Restarting container '$CONTAINER'"
    "$DOCKER" restart "$CONTAINER" >/dev/null
    # Poll until MA's HTTP /info responds 200 with status=running
    local base_url
    base_url=$("$DOCKER" exec "$CONTAINER" sh -c 'echo ${MASS_BASE_URL:-http://localhost:8095}' 2>/dev/null || true)
    [ -z "$base_url" ] && base_url="http://localhost:8095"

    echo ">> Waiting for MA to answer on ${base_url}/info ..."
    for i in $(seq 1 30); do
        if "$DOCKER" exec "$CONTAINER" sh -c "wget -qO- ${base_url}/info 2>/dev/null || curl -s ${base_url}/info 2>/dev/null" | grep -q '"status":"running"'; then
            echo ">> MA is back up."
            return 0
        fi
        sleep 2
    done
    echo "WARN: MA did not report status=running within 60s — check logs manually." >&2
}

case "${1:-}" in
    --revert)
        revert
        restart
        ;;
    --no-restart)
        apply
        echo ">> Patch applied. Container NOT restarted — change takes effect on next restart."
        ;;
    "")
        apply
        restart
        ;;
    *)
        echo "Usage: $0 [--no-restart|--revert]" >&2
        exit 2
        ;;
esac
