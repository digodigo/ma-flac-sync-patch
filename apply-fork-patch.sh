#!/usr/bin/env bash
#
# apply-fork-patch.sh — deploy the upstream-fork version of the
# squeezelite sync codec fix into the running Music Assistant 2.8.7
# Docker container, for hardware verification before the upstream PR
# is merged.
#
# Unlike the sibling apply-patch.sh (one-line sed: fmt=flac → fmt=mp3),
# this script copies a fully-rewritten player.py into the container.
# The replacement file is the same fix that's being proposed upstream,
# backported to the 2.8.7 source tree.
#
# Effect on hardware:
#   - Classic Squeezeboxes in a sync group: codec resolves to mp3
#     (HELO advertises only pcm/mp3) → audible.
#   - Modern Squeezelite / SqueezeESP32 in a sync group: keeps FLAC
#     (HELO advertises pcm/mp3/flc).
#   - Mixed groups: each child gets the best codec it can decode.
#
# Run on the Docker host, same as apply-patch.sh.
#
# Usage:
#   ./apply-fork-patch.sh                # apply + restart
#   ./apply-fork-patch.sh --no-restart   # apply only
#   ./apply-fork-patch.sh --revert       # restore previous .bak.* and restart
#   CONTAINER=my-mass ./apply-fork-patch.sh
#
# Re-apply after every MA Docker image update (same caveat as apply-patch.sh).

set -euo pipefail

CONTAINER="${CONTAINER:-music-assistant}"
TARGET="/app/venv/lib/python3.13/site-packages/music_assistant/providers/squeezelite/player.py"
SOURCE_FILE="$(cd "$(dirname "$0")" && pwd)/fork-patch/player.py"

# Detect docker binary (Synology has it under /usr/local/bin)
DOCKER="${DOCKER:-$(command -v docker || true)}"
if [ -z "$DOCKER" ] && [ -x /usr/local/bin/docker ]; then
    DOCKER=/usr/local/bin/docker
fi
if [ -z "$DOCKER" ]; then
    echo "ERROR: docker binary not found in PATH" >&2
    exit 1
fi

if [ ! -f "$SOURCE_FILE" ]; then
    echo "ERROR: replacement file not found at $SOURCE_FILE" >&2
    exit 1
fi

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
    # Detect already-patched state by looking for the new helper symbol.
    if "$DOCKER" exec "$CONTAINER" grep -q '_resolve_child_codec' "$TARGET"; then
        echo ">> Already patched (found _resolve_child_codec). Nothing to do."
        return 0
    fi

    # Sanity: target file should still contain the upstream-broken line.
    if ! "$DOCKER" exec "$CONTAINER" grep -q 'fmt=flac' "$TARGET"; then
        echo "ERROR: unexpected target state — neither '_resolve_child_codec' nor 'fmt=flac'" >&2
        echo "       found in $TARGET. Has the MA codebase changed?" >&2
        echo "       Check manually: $DOCKER exec $CONTAINER grep -n 'fmt=' $TARGET" >&2
        exit 1
    fi

    local stamp
    stamp=$(date +%Y%m%d_%H%M%S)
    echo ">> Backing up to ${TARGET}.bak.${stamp}"
    "$DOCKER" exec "$CONTAINER" cp "$TARGET" "${TARGET}.bak.${stamp}"

    echo ">> Copying patched player.py into container"
    "$DOCKER" cp "$SOURCE_FILE" "${CONTAINER}:${TARGET}"

    echo ">> Verifying"
    if "$DOCKER" exec "$CONTAINER" grep -q '_resolve_child_codec' "$TARGET" \
       && ! "$DOCKER" exec "$CONTAINER" grep -q 'fmt=flac' "$TARGET"; then
        echo ">> Patch applied successfully."
    else
        echo "ERROR: post-apply verification failed" >&2
        exit 1
    fi
}

restart() {
    echo ">> Restarting container '$CONTAINER'"
    "$DOCKER" restart "$CONTAINER" >/dev/null
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
