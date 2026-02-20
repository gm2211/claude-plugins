#!/usr/bin/env bash
# Close Zellij dashboard panes (beads, deploys) by killing the
# processes that run inside them.  When a process exits, Zellij automatically
# closes the pane.
#
# Called by the SessionEnd hook when a Claude Code session exits.
# Fails silently when not running inside Zellij.

set -euo pipefail

# ---------------------------------------------------------------------------
# Debug logging
# ---------------------------------------------------------------------------
LOG="/tmp/close-dashboard-debug.log"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

log "close-dashboard.sh invoked (PID=$$, ZELLIJ=${ZELLIJ:-unset}, PWD=${PWD})"

# ---------------------------------------------------------------------------
# Read the hook input JSON from stdin.
# Claude Code passes a JSON object with hook_event_name, session_id, etc.
# ---------------------------------------------------------------------------
HOOK_INPUT=""
if ! [ -t 0 ]; then
  HOOK_INPUT=$(cat)
fi

HOOK_EVENT=""
if [[ -n "$HOOK_INPUT" ]]; then
  HOOK_EVENT=$(printf '%s' "$HOOK_INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
fi

log "Hook event: ${HOOK_EVENT:-unknown} (input length: ${#HOOK_INPUT})"
log "Hook input: ${HOOK_INPUT}"

# If not inside Zellij, bail silently
if [[ -z "${ZELLIJ:-}" ]]; then
  log "Not inside Zellij — exiting."
  exit 0
fi

# ---------------------------------------------------------------------------
# Determine the project directory to scope process matching.
# This prevents killing dashboard panes belonging to other sessions.
# ---------------------------------------------------------------------------
PROJECT_DIR="${PWD}"
if git rev-parse --show-toplevel &>/dev/null; then
  PROJECT_DIR="$(git rev-parse --show-toplevel)"
fi

log "Project directory: $PROJECT_DIR"

# ---------------------------------------------------------------------------
# Check if there's still an active Claude process for this project.
# If so, another Claude session is still running — don't close panes.
#
# We intentionally do NOT use get_focused_tab_layout() here because it
# returns the FOCUSED tab (where the user currently is), not the tab that
# fired the SessionEnd event.  Inspecting the focused tab leads to false
# positives: a SessionEnd from project A would examine project B's tab and
# see 0 Claude panes, then incorrectly kill project A's dashboard.
#
# Instead, we count running "claude" processes whose working directory
# matches PROJECT_DIR.  This is tab-agnostic and correctly identifies
# whether another Claude session for THIS project is still active.
# ---------------------------------------------------------------------------

# Count running claude processes whose cwd matches PROJECT_DIR.
# We exclude the current shell's own PID to avoid counting ourselves.
count_active_claude_sessions() {
  local project_dir="$1"
  local count=0
  local pids
  pids=$(pgrep -x claude 2>/dev/null || pgrep -f 'claude' 2>/dev/null || true)
  for pid in $pids; do
    [[ "$pid" == "$$" ]] && continue
    local cwd
    cwd=$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//' || true)
    if [[ "$cwd" == "$project_dir" ]]; then
      (( count++ )) || true
    fi
  done
  echo "$count"
}

# Extract the dashboard instance ID from pane names in the layout.
# We still need this for tab-scoped killing via DASH_ID.
# We read all tabs (not just focused) to find the one belonging to
# this session's PROJECT_DIR via the dashboard pane names.
get_all_tabs_layout() {
  zellij action dump-layout 2>/dev/null || true
}

extract_dashboard_id_from_layout() {
  local layout="$1"
  local id=""
  while IFS= read -r line; do
    if [[ "$line" =~ name=\"dashboard-(beads|deploys)-([a-f0-9]+)\" ]]; then
      id="${BASH_REMATCH[2]}"
      break
    fi
  done <<< "$layout"
  echo "$id"
}

all_layout=$(get_all_tabs_layout 2>/dev/null) || all_layout=""

# Find the DASH_ID associated with this project.
# Strategy 1: Extract from pane names in the layout (works for all named panes).
DASH_ID=$(extract_dashboard_id_from_layout "$all_layout")

# Strategy 2 (legacy fallback): Scan watch-*.py processes for the DASH_ID arg.
if [[ -z "$DASH_ID" ]]; then
  for script in "watch-deploys.py"; do
    pids=$(pgrep -f "$script" 2>/dev/null || true)
    for pid in $pids; do
      cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
      # cmdline: python3 .../watch-deploys.py /path/to/project <dash_id>
      read -ra words <<< "$cmdline"
      for i in "${!words[@]}"; do
        if [[ "${words[$i]}" == "$PROJECT_DIR" ]]; then
          next_idx=$(( i + 1 ))
          if [[ $next_idx -lt ${#words[@]} ]]; then
            candidate="${words[$next_idx]}"
            if [[ "$candidate" =~ ^[a-f0-9]{8}$ ]]; then
              DASH_ID="$candidate"
              break 3
            fi
          fi
        fi
      done
    done
  done
fi

log "Dashboard ID derived from running processes: ${DASH_ID:-none}"

active_sessions=$(count_active_claude_sessions "$PROJECT_DIR")
log "Active Claude sessions for project: $active_sessions"

if [[ "$active_sessions" -ge 1 ]]; then
  log "Skipping pane cleanup — $active_sessions Claude session(s) still active for $PROJECT_DIR"
  exit 0
fi

# ---------------------------------------------------------------------------
# Kill a process and all its descendants (children, grandchildren, etc.).
# Uses SIGTERM so watch scripts can run their cleanup traps.
# ---------------------------------------------------------------------------
kill_tree() {
  local pid="$1"
  local label="$2"

  # First, collect child PIDs before killing the parent (once the parent
  # dies, child reparenting may make them harder to associate).
  local children
  children=$(pgrep -P "$pid" 2>/dev/null || true)

  log "Sending SIGTERM to PID $pid ($label)"
  kill "$pid" 2>/dev/null || true

  # Recursively kill children
  if [[ -n "$children" ]]; then
    for child in $children; do
      log "  Sending SIGTERM to child PID $child (parent=$pid, $label)"
      kill_tree "$child" "$label/child"
    done
  fi
}

# ---------------------------------------------------------------------------
# Kill processes running the dashboard watch scripts for THIS project.
#
# open-dashboard.sh creates panes with:
#   python3 "${SCRIPT_DIR}/watch-*.py" "${PROJECT_DIR}"
#
# Each process's cmdline contains PROJECT_DIR as an argument, so we can
# match them directly.  We still kill the full process tree to handle any
# child processes (e.g. fswatch spawned by watch-deploys.py).
# ---------------------------------------------------------------------------

WATCH_SCRIPTS=("nvim" "watch-deploys.py")

killed=0
for script in "${WATCH_SCRIPTS[@]}"; do
  # Find PIDs whose command line contains the script name.
  pids=$(pgrep -f "$script" 2>/dev/null || true)

  if [[ -z "$pids" ]]; then
    log "No process found for $script"
    continue
  fi

  for pid in $pids; do
    # Skip our own PID to avoid self-kill
    if [[ "$pid" == "$$" ]]; then
      continue
    fi

    # Read the full command line to check project scope.
    cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)

    if [[ -z "$cmdline" ]]; then
      log "Cannot read cmdline for PID $pid ($script) — skipping"
      continue
    fi

    if [[ -n "$DASH_ID" && "$cmdline" == *"$DASH_ID"* ]]; then
      # Tab-scoped: kill processes whose cmdline contains this dashboard ID
      log "Killing PID $pid ($script) — matched DASH_ID $DASH_ID"
      log "  cmdline: $cmdline"
      kill_tree "$pid" "$script"
      (( killed++ )) || true
      continue
    fi

    # Match by PROJECT_DIR — used when DASH_ID is absent (legacy) or when
    # the process doesn't embed DASH_ID in its cmdline (nvim doesn't use DASH_ID).
    if [[ -n "$DASH_ID" && "$script" != "nvim" ]]; then
      # For watch-*.py with a known DASH_ID, skip PROJECT_DIR fallback —
      # DASH_ID should have matched above if this process belongs to us.
      :
    else
      cmdline_exact_match=false
      if [[ "$script" == "nvim" ]]; then
        # Substring match: nvim beads pane may reference PROJECT_DIR
        if [[ "$cmdline" == *"$PROJECT_DIR"* ]]; then
          cmdline_exact_match=true
        fi
      else
        read -ra cmdline_words <<< "$cmdline"
        for word in "${cmdline_words[@]}"; do
          if [[ "$word" == "$PROJECT_DIR" ]]; then
            cmdline_exact_match=true
            break
          fi
        done
      fi

      if $cmdline_exact_match; then
        log "Killing PID $pid ($script) — matched PROJECT_DIR (exact)"
        log "  cmdline: $cmdline"
        kill_tree "$pid" "$script"
        (( killed++ )) || true
        continue
      fi

      # Parent match: this process is a child of a wrapper whose cmdline
      # contains our project directory (exact word match).
      ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
      if [[ -n "$ppid" && "$ppid" != "1" ]]; then
        parent_cmdline=$(ps -p "$ppid" -o args= 2>/dev/null || true)
        parent_exact_match=false
        read -ra parent_words <<< "$parent_cmdline"
        for word in "${parent_words[@]}"; do
          if [[ "$word" == "$PROJECT_DIR" ]]; then
            parent_exact_match=true
            break
          fi
        done
        if $parent_exact_match; then
          log "Killing PID $pid ($script) — matched via parent PID $ppid (exact)"
          log "  cmdline: $cmdline"
          kill_tree "$pid" "$script"
          (( killed++ )) || true
          continue
        fi
      fi
    fi

    log "Skipping PID $pid ($script) — belongs to different project/tab"
    log "  cmdline: $cmdline"
  done
done

# Give processes a moment to handle SIGTERM and exit cleanly.
# This ensures Zellij sees the process exit and can close the pane
# before this script (and the SessionEnd hook) finishes.
if [[ $killed -gt 0 ]]; then
  sleep 0.5
fi

log "Done — sent SIGTERM to $killed process(es)."
exit 0
