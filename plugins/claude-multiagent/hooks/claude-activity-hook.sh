#!/usr/bin/env bash
# Claude Code hook: sends activity status to zjstatus and renames the current
# tab when Claude needs input, so background tabs are visually highlighted.
#
# Triggered on Stop, Notification, and SessionEnd events.
# Reads hook event JSON from stdin, maps to zjstatus pipe_status and tab name.
#
# Tab notification strategy:
#   - We find this pane's tab name by matching $PWD against dump-layout output.
#   - On Notification: prepend "● " to the tab name (if not already present).
#   - On Stop: strip the "● " prefix from the tab name (if present).
#   - To rename a tab we must first switch to it, rename, then switch back.
#   - We track the originally focused tab so we can restore it after renaming.

set -euo pipefail

# Allow per-launch opt-out from shell wrapper.
if [[ "${CLAUDE_MULTIAGENT_DISABLE:-}" == "1" ]]; then
    exit 0
fi

# Only run inside a zellij session
if [ -z "${ZELLIJ:-}" ]; then
    exit 0
fi

# ── Helpers ────────────────────────────────────────────────────────────────

# Returns the name of the focused tab (the one the user is currently looking at)
# by finding the tab line that has "focus=true" in the dump-layout output.
# Uses portable POSIX awk (no gawk extensions) — compatible with BSD awk on macOS.
# Optional $1: pre-fetched layout text; if omitted, calls dump-layout itself.
get_focused_tab_name() {
    local layout_text
    if [ -n "${1:-}" ]; then
        layout_text="$1"
    else
        layout_text="$(zellij action dump-layout 2>/dev/null)"
    fi

    printf '%s\n' "$layout_text" \
        | awk '
            /tab name=/ {
                line = $0
                sub(/.*name="/, "", line)
                sub(/".*/, "", line)
                name = line
                if ($0 ~ /focus=true|is_focused=true|active=true|selected=true|current=true|focus true|is_focused true/) {
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
# $1: target cwd path (required)
# Optional $2: pre-fetched layout text; if omitted, calls dump-layout itself.
get_tab_name_for_cwd() {
    local target_cwd="$1"
    local basename_cwd
    basename_cwd="$(basename "$target_cwd")"

    local layout_text
    if [ -n "${2:-}" ]; then
        layout_text="$2"
    else
        layout_text="$(zellij action dump-layout 2>/dev/null)"
    fi

    printf '%s\n' "$layout_text" \
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
HOOK_TYPE=$(printf '%s' "$EVENT" | jq -r '.hook_event_name // .type // .event // empty')

# ── Per-tab rename logic ────────────────────────────────────────────────────

NOTIFICATION_PREFIX="● "

# ── Tab name cache ─────────────────────────────────────────────────────────
# Cache the tab name after first successful identification to avoid repeated
# dump-layout calls (each takes 1-3s and is fragile with CWD matching).
# Cache is keyed by PWD so each session gets its own file.

_pwd_hash() {
    # Portable hash: works on macOS (md5) and Linux (md5sum)
    if command -v md5 >/dev/null 2>&1; then
        printf '%s' "$PWD" | md5 | cut -c1-8
    elif command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$PWD" | md5sum | cut -c1-8
    else
        # Fallback: use a simple checksum from cksum
        printf '%s' "$PWD" | cksum | awk '{print $1}'
    fi
}

TAB_NAME_CACHE="${TMPDIR:-/tmp}/claude-tab-name-$(_pwd_hash)"
TAB_NAME_CACHE_MAX_AGE=300  # 5 minutes in seconds

# Read cached tab name if the cache file exists and is recent enough.
# Returns 0 (success) if cache hit, 1 if miss/stale.
_read_tab_cache() {
    if [ ! -f "$TAB_NAME_CACHE" ]; then
        return 1
    fi
    # Check age: file must be less than TAB_NAME_CACHE_MAX_AGE seconds old.
    # Use portable stat for macOS (-f %m) vs Linux (-c %Y).
    local file_mtime now age
    if stat -f %m "$TAB_NAME_CACHE" >/dev/null 2>&1; then
        file_mtime=$(stat -f %m "$TAB_NAME_CACHE")
    else
        file_mtime=$(stat -c %Y "$TAB_NAME_CACHE" 2>/dev/null) || return 1
    fi
    now=$(date +%s)
    age=$((now - file_mtime))
    if [ "$age" -ge "$TAB_NAME_CACHE_MAX_AGE" ]; then
        return 1
    fi
    cat "$TAB_NAME_CACHE"
    return 0
}

# Write the tab name to the cache file.
_write_tab_cache() {
    printf '%s' "$1" > "$TAB_NAME_CACHE"
}

# Remove the cache file (used on SessionEnd).
_clear_tab_cache() {
    rm -f "$TAB_NAME_CACHE"
}

do_tab_rename() {
    local mode="$1"   # "add" or "remove"

    # Try to use cached base tab name to avoid expensive dump-layout call.
    # The cache always stores the base name (without notification prefix).
    local base_tab_name=""
    local cached_name
    cached_name="$(_read_tab_cache)" && base_tab_name="$cached_name"

    local layout=""

    if [ -z "$base_tab_name" ]; then
        # Cache miss — fetch layout once and reuse for both helper calls
        layout="$(zellij action dump-layout 2>/dev/null)"

        # Find the tab that contains this Claude session (by its working directory)
        local found_name
        found_name="$(get_tab_name_for_cwd "${PWD}" "$layout")"

        if [ -n "$found_name" ]; then
            # Strip the notification prefix before caching (cache the base name)
            base_tab_name="${found_name#"${NOTIFICATION_PREFIX}"}"
            _write_tab_cache "$base_tab_name"
        fi
    fi

    # Find which tab is currently focused (used both for the focused-tab guard and
    # to restore focus after renaming)
    local focused_tab
    if [ -z "$layout" ]; then
        focused_tab="$(get_focused_tab_name)"
    else
        focused_tab="$(get_focused_tab_name "$layout")"
    fi

    if [ -z "$base_tab_name" ]; then
        # Fallback: when cwd matching fails, clear the marker from the tab
        # the user is currently viewing.
        if [ "$mode" = "remove" ] && [ -n "$focused_tab" ] && [[ "$focused_tab" == "${NOTIFICATION_PREFIX}"* ]]; then
            base_tab_name="${focused_tab#"${NOTIFICATION_PREFIX}"}"
        else
            # Cannot determine our tab — skip tab rename, only do global pipe
            return
        fi
    fi

    # Determine current and target tab names based on mode.
    # base_tab_name is always the name without the prefix.
    local current_name new_name
    if [ "$mode" = "add" ]; then
        current_name="$base_tab_name"
        new_name="${NOTIFICATION_PREFIX}${base_tab_name}"

        # Don't add dot if user is already looking at this tab
        if [ "$focused_tab" = "$current_name" ] || [ "$focused_tab" = "$new_name" ]; then
            return  # User can already see this tab
        fi
    else
        current_name="${NOTIFICATION_PREFIX}${base_tab_name}"
        new_name="$base_tab_name"
    fi

    # Switch to our tab, rename it, then restore focus.
    # If go-to-tab-name fails (tab doesn't exist with that name), skip the
    # rename entirely to avoid renaming whichever tab happens to be focused.
    if zellij action go-to-tab-name "$current_name" 2>/dev/null; then
        zellij action rename-tab "$new_name" 2>/dev/null || true

        # Restore focus to the previously focused tab (if different)
        if [ -n "$focused_tab" ] && [ "$focused_tab" != "$current_name" ]; then
            zellij action go-to-tab-name "$focused_tab" 2>/dev/null || true
        fi
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
    "SessionEnd"|"session_end")
        # Session is ending — strip dot prefix and clear pipe_status.
        # This runs before close-dashboard.sh (which changes the layout).
        do_tab_rename "remove"
        # Clear pipe_status so the bar doesn't show stale state
        zellij action pipe --name zjstatus --args "pipe_status" -- "" 2>/dev/null || true
        # Clean up the tab name cache file
        _clear_tab_cache
        ;;
esac
