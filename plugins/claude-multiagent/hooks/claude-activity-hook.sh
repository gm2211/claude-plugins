#!/usr/bin/env bash
# Claude Code hook: sends activity status to zjstatus via zellij pipe.
# Triggered on Stop and Notification events.
# Reads hook event JSON from stdin, maps to zjstatus pipe_status.

set -euo pipefail

# Only run inside a zellij session
if [ -z "${ZELLIJ:-}" ]; then
    exit 0
fi

EVENT=$(cat)
HOOK_TYPE=$(echo "$EVENT" | jq -r '.type // .event // empty')

case "$HOOK_TYPE" in
    "Stop"|"stop")
        zellij action pipe --name zjstatus --args "pipe_status" -- "#[fg=#a6e3a1,bold]✓ done"
        ;;
    "Notification"|"notification")
        zellij action pipe --name zjstatus --args "pipe_status" -- "#[fg=#f38ba8,bold]? input needed"
        ;;
esac
