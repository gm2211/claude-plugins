#!/usr/bin/env bash
# Claude Code hook: sends activity status to zjstatus and renames the current
# tab when Claude needs input, so background tabs are visually highlighted.
#
# Triggered on Stop and Notification events.
# Reads hook event JSON from stdin, maps to zjstatus pipe_status and tab name.
#
# Tab notification strategy:
#   - We find this pane's tab name by matching $PWD against dump-layout output.
#   - On Notification: prepend "● " to the tab name (if not already present).
#   - On Stop: strip the "● " prefix from the tab name (if present).
#   - To rename a tab we must first switch to it, rename, then switch back.
#   - We track the originally focused tab so we can restore it after renaming.

set -euo pipefail

# Only run inside a zellij session
if [ -z "${ZELLIJ:-}" ]; then
    exit 0
fi

# ── Helpers ────────────────────────────────────────────────────────────────

# Returns the name of the focused tab (the one the user is currently looking at)
# by finding the tab line that has "focus=true" in the dump-layout output.
# Uses portable POSIX awk (no gawk extensions) — compatible with BSD awk on macOS.
get_focused_tab_name() {
    zellij action dump-layout 2>/dev/null \
        | awk '
            /tab name=/ {
                line = $0
                sub(/.*name="/, "", line)
                sub(/".*/, "", line)
                name = line
                if ($0 ~ /focus=true/) {
                    print name
                }
            }
        '
}

# Returns the tab name that contains the pane whose cwd matches the given path.
# Scans dump-layout: when we enter a tab block, we record its name; when we
# see a pane with a matching cwd, we emit the current tab name.
# Handles both absolute cwd (/Users/foo/project) and relative cwd (project).
# Uses portable POSIX awk (no gawk extensions) — compatible with BSD awk on macOS.
get_tab_name_for_cwd() {
    local target_cwd="$1"
    local basename_cwd
    basename_cwd="$(basename "$target_cwd")"

    zellij action dump-layout 2>/dev/null \
        | awk -v target="$target_cwd" -v base="$basename_cwd" '
            /tab name=/ {
                line = $0
                sub(/.*name="/, "", line)
                sub(/".*/, "", line)
                current_tab = line
            }
            /cwd=/ {
                if (found) next
                line = $0
                sub(/.*cwd="/, "", line)
                sub(/".*/, "", line)
                cwd_val = line
                matched = 0
                # Exact full path match
                if (cwd_val == target) matched = 1
                # Bare basename match (relative cwd in dump-layout)
                if (cwd_val == base) matched = 1
                # Path ending with /basename
                if (matched == 0 && length(cwd_val) > length(base)) {
                    suffix = "/" base
                    end = substr(cwd_val, length(cwd_val) - length(suffix) + 1)
                    if (end == suffix) matched = 1
                }
                if (matched == 1 && current_tab != "") {
                    print current_tab
                    found = 1
                }
            }
        '
}

# ── Parse event ────────────────────────────────────────────────────────────

EVENT=$(cat)
HOOK_TYPE=$(printf '%s' "$EVENT" | jq -r '.type // .event // empty')

# ── Per-tab rename logic ────────────────────────────────────────────────────

NOTIFICATION_PREFIX="● "

do_tab_rename() {
    local mode="$1"   # "add" or "remove"

    # Find the tab that contains this Claude session (by its working directory)
    local our_tab_name
    our_tab_name="$(get_tab_name_for_cwd "${PWD}")"

    if [ -z "$our_tab_name" ]; then
        # Cannot determine our tab — skip tab rename, only do global pipe
        return
    fi

    # Compute the new tab name
    local new_name
    if [ "$mode" = "add" ]; then
        # Only add prefix if not already present
        if [[ "$our_tab_name" == "${NOTIFICATION_PREFIX}"* ]]; then
            return  # Already marked, nothing to do
        fi
        new_name="${NOTIFICATION_PREFIX}${our_tab_name}"
    else
        # Remove prefix if present
        if [[ "$our_tab_name" != "${NOTIFICATION_PREFIX}"* ]]; then
            return  # No prefix, nothing to strip
        fi
        new_name="${our_tab_name#"${NOTIFICATION_PREFIX}"}"
    fi

    # Find which tab is currently focused so we can restore focus afterwards
    local focused_tab
    focused_tab="$(get_focused_tab_name)"

    # Switch to our tab, rename it, then restore focus
    zellij action go-to-tab-name "$our_tab_name" 2>/dev/null || true
    zellij action rename-tab "$new_name" 2>/dev/null || true

    # Restore focus to the previously focused tab (if different)
    if [ -n "$focused_tab" ] && [ "$focused_tab" != "$our_tab_name" ]; then
        zellij action go-to-tab-name "$focused_tab" 2>/dev/null || true
    fi
}

# ── Main dispatch ──────────────────────────────────────────────────────────

case "$HOOK_TYPE" in
    "Stop"|"stop")
        # Strip the notification indicator from this tab's name
        do_tab_rename "remove"
        # Update global pipe_status in zjstatus
        zellij action pipe --name zjstatus --args "pipe_status" -- "#[fg=#a6e3a1,bold]✓ done"
        ;;
    "Notification"|"notification")
        # Mark this tab with a notification indicator
        do_tab_rename "add"
        # Update global pipe_status in zjstatus
        zellij action pipe --name zjstatus --args "pipe_status" -- "#[fg=#f38ba8,bold]? input needed"
        ;;
esac
