#!/usr/bin/env bash
# Claude Code hook: sends activity status to zjstatus and notifies the user
# via the zellij-attention WASM plugin when Claude needs input in a background tab.
#
# Triggered on Stop, Notification, and SessionEnd events.
# Reads hook event JSON from stdin, maps to zjstatus pipe_status and
# zellij-attention pipe messages (which append/clear icons on the tab name).
#
# Inside Docker (clauded), also writes a signal file to ~/.claude/notify/
# so the host-side bridge can update the host zellij tab icons.

set -euo pipefail

# Allow per-launch opt-out from shell wrapper.
if [[ "${CLAUDE_MULTIAGENT_DISABLE:-}" == "1" ]]; then
    exit 0
fi

# ── Helpers ──────────────────────────────────────────────────────────────

# Desktop notification via OSC 99 (kitty notification protocol).
# Works without the kitten binary — raw escape sequences propagate through
# terminal layers including from Docker containers.
desktop_notify() {
    local title="$1" body="${2:-}"
    # OSC 99 with identifier, urgency=normal
    printf '\e]99;i=claude-activity:d=0;%s\e\\' "$title" 2>/dev/null || true
    if [ -n "$body" ]; then
        printf '\e]99;i=claude-activity:d=1:p=body;%s\e\\' "$body" 2>/dev/null || true
    fi
}

# Write signal file for host-side bridge (clauded Docker sessions).
# The host bridge watches the mounted host ~/.claude/notify/ directory and
# translates signals to host zellij pipe commands.
signal_host() {
    local event_type="$1"
    local signal_dir=""
    # Only signal if we're in Docker (clauded).
    if [ -f /.dockerenv ]; then
        for candidate in /Users/*/.claude /home/*/.claude; do
            [ "$candidate" = "$HOME/.claude" ] && continue
            [ -d "$candidate" ] || continue
            signal_dir="$candidate/notify"
            break
        done
    fi
    if [ -n "$signal_dir" ] && mkdir -p "$signal_dir" 2>/dev/null; then
        printf '%s\n' "$event_type" > "$signal_dir/signal"
    fi
}

# ── Parse event ──────────────────────────────────────────────────────────

EVENT=$(cat)
HOOK_TYPE=$(printf '%s' "$EVENT" | jq -r '.hook_event_name // .type // .event // empty')

# ── Main dispatch ────────────────────────────────────────────────────────

case "$HOOK_TYPE" in
    "Stop"|"stop")
        signal_host "completed"
        desktop_notify "Agent Complete" "Task finished"
        if [ -n "${ZELLIJ:-}" ]; then
            zellij pipe --name "zellij-attention::completed::$ZELLIJ_PANE_ID"
            zellij action pipe --name zjstatus --args "pipe_status" -- "#[fg=#a6e3a1,bold]✓ done"
        fi
        ;;
    "Notification"|"notification")
        signal_host "waiting"
        desktop_notify "Needs Attention" "Agent is waiting for input"
        if [ -n "${ZELLIJ:-}" ]; then
            zellij pipe --name "zellij-attention::waiting::$ZELLIJ_PANE_ID"
            zellij action pipe --name zjstatus --args "pipe_status" -- "#[fg=#f38ba8,bold]? input needed"
        fi
        ;;
    "SessionEnd"|"session_end")
        signal_host "clear"
        if [ -n "${ZELLIJ:-}" ]; then
            zellij pipe --name "zellij-attention::completed::$ZELLIJ_PANE_ID"
            zellij action pipe --name zjstatus --args "pipe_status" -- "" 2>/dev/null || true
        fi
        ;;
esac
