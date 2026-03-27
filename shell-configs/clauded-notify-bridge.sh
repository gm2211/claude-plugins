#!/usr/bin/env bash
# clauded-notify-bridge.sh — host-side watcher that translates Docker container
# notification signals into host zellij tab icon updates.
#
# Usage: clauded-notify-bridge.sh <ZELLIJ_PANE_ID>
#
# The container's activity hook writes "waiting", "completed", or "clear" to
# ~/.claude/notify/signal. This script polls that file and sends the
# corresponding zellij pipe commands to update the host zellij tab icons.
#
# Started automatically by clauded() in the background. Exits when the signal
# dir is removed or the parent zellij pane no longer exists.

set -euo pipefail

PANE_ID="${1:?Usage: clauded-notify-bridge.sh <ZELLIJ_PANE_ID>}"
SIGNAL_DIR="$HOME/.claude/notify"
SIGNAL_FILE="$SIGNAL_DIR/signal"
POLL_INTERVAL=2  # seconds

# Ensure signal dir exists
mkdir -p "$SIGNAL_DIR"

# Track last signal to avoid duplicate zellij pipe calls
last_signal=""

cleanup() {
    rm -f "$SIGNAL_FILE" 2>/dev/null
    exit 0
}
trap cleanup EXIT INT TERM

while true; do
    # Exit if not inside zellij anymore
    if [ -z "${ZELLIJ:-}" ]; then
        break
    fi

    if [ -f "$SIGNAL_FILE" ]; then
        signal=$(cat "$SIGNAL_FILE" 2>/dev/null || true)
        # Only act if signal changed
        if [ -n "$signal" ] && [ "$signal" != "$last_signal" ]; then
            last_signal="$signal"
            case "$signal" in
                waiting)
                    zellij pipe --name "zellij-attention::waiting::$PANE_ID" 2>/dev/null || true
                    ;;
                completed)
                    zellij pipe --name "zellij-attention::completed::$PANE_ID" 2>/dev/null || true
                    ;;
                clear)
                    zellij pipe --name "zellij-attention::completed::$PANE_ID" 2>/dev/null || true
                    rm -f "$SIGNAL_FILE" 2>/dev/null
                    last_signal=""
                    ;;
            esac
        fi
    else
        last_signal=""
    fi

    sleep "$POLL_INTERVAL"
done
