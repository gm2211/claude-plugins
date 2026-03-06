#!/usr/bin/env bash
# Claude Code hook: sends activity status to zjstatus and notifies the user
# via the zellij-attention WASM plugin when Claude needs input in a background tab.
#
# Triggered on Stop, Notification, and SessionEnd events.
# Reads hook event JSON from stdin, maps to zjstatus pipe_status and
# zellij-attention pipe messages (which append/clear icons on the tab name).

set -euo pipefail

# Allow per-launch opt-out from shell wrapper.
if [[ "${CLAUDE_MULTIAGENT_DISABLE:-}" == "1" ]]; then
    exit 0
fi

# Only run inside a zellij session
if [ -z "${ZELLIJ:-}" ]; then
    exit 0
fi

# ── Parse event ────────────────────────────────────────────────────────────

EVENT=$(cat)
HOOK_TYPE=$(printf '%s' "$EVENT" | jq -r '.hook_event_name // .type // .event // empty')

# ── Main dispatch ──────────────────────────────────────────────────────────

case "$HOOK_TYPE" in
    "Stop"|"stop")
        zellij pipe --name "zellij-attention::completed::$ZELLIJ_PANE_ID"
        zellij action pipe --name zjstatus --args "pipe_status" -- "#[fg=#a6e3a1,bold]✓ done"
        ;;
    "Notification"|"notification")
        zellij pipe --name "zellij-attention::waiting::$ZELLIJ_PANE_ID"
        zellij action pipe --name zjstatus --args "pipe_status" -- "#[fg=#f38ba8,bold]? input needed"
        ;;
    "SessionEnd"|"session_end")
        zellij pipe --name "zellij-attention::completed::$ZELLIJ_PANE_ID"
        zellij action pipe --name zjstatus --args "pipe_status" -- "" 2>/dev/null || true
        ;;
esac
