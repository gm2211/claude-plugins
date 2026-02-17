#!/usr/bin/env bash
# Close Zellij dashboard panes (beads, agents, deploys) by killing the
# processes that run inside them.  When a process exits, Zellij automatically
# closes the pane.
#
# Called by the Stop and SessionEnd hooks when a Claude Code session ends.
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

# ---------------------------------------------------------------------------
# Don't close panes when sub-agents stop — only the main session should.
#
# Primary check: the hook_event_name from stdin. Claude Code sends "Stop"
# for the main session and "SubagentStop" for sub-agents.
#
# Fallback check: the working directory. Sub-agents using worktrees run
# in .worktrees/ directories. This catches edge cases where stdin is empty.
# ---------------------------------------------------------------------------
if [[ "$HOOK_EVENT" == "SubagentStop" ]]; then
  log "Skipping pane cleanup — SubagentStop event (sub-agent terminated)"
  exit 0
fi

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

# Fallback sub-agent check: worktree-based sub-agents run in .worktrees/
if [[ "$PROJECT_DIR" == *".worktrees/"* ]]; then
  log "Skipping pane cleanup — running in a worktree (sub-agent context)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Check if there's still an active Claude pane in the focused tab.
# If so, another Claude session is still running — don't close panes.
# ---------------------------------------------------------------------------

# Extract the focused tab block from dump-layout output.
get_focused_tab_layout() {
  local layout
  layout=$(zellij action dump-layout 2>/dev/null) || return 1

  local in_focused=0
  local depth=0
  local result=""

  while IFS= read -r line; do
    if [[ $in_focused -eq 0 ]]; then
      if [[ "$line" =~ ^[[:space:]]*tab[[:space:]].*focus=true ]]; then
        in_focused=1
        depth=1
        result="$line"$'\n'
      fi
    else
      result+="$line"$'\n'
      local opens="${line//[^\{]/}"
      local closes="${line//[^\}]/}"
      depth=$(( depth + ${#opens} - ${#closes} ))
      if [[ $depth -le 0 ]]; then
        break
      fi
    fi
  done <<< "$layout"

  printf '%s' "$result"
}

# Count how many panes in the layout run the "claude" command.
count_claude_panes() {
  local layout="$1"
  local count=0
  while IFS= read -r line; do
    if [[ "$line" =~ command=\"claude\" ]]; then
      (( count++ ))
    fi
  done <<< "$layout"
  echo "$count"
}

focused_tab=$(get_focused_tab_layout 2>/dev/null) || focused_tab=""
claude_pane_count=0
if [[ -n "$focused_tab" ]]; then
  claude_pane_count=$(count_claude_panes "$focused_tab")
fi

log "Claude pane check: found $claude_pane_count Claude pane(s) in focused tab"

if [[ "$claude_pane_count" -ge 2 ]]; then
  log "Skipping pane cleanup — $claude_pane_count Claude pane(s) still active in tab"
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
#   bash -c "cd '${PROJECT_DIR}' && '${SCRIPT_DIR}/watch-*.sh'"
#
# This spawns a process tree:
#   1. bash -c "cd '/project' && '/path/to/watch-beads.sh'"   (wrapper)
#   2.   /bin/bash /path/to/watch-beads.sh                    (child)
#
# The wrapper's cmdline contains PROJECT_DIR, but the child's does NOT.
# We must kill the entire process tree — if we only kill the wrapper, the
# child keeps running and the Zellij pane stays open.
# ---------------------------------------------------------------------------

WATCH_SCRIPTS=("watch-beads.sh" "watch-agents.sh" "watch-deploys.sh")

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

    # Direct match: process cmdline contains our project directory.
    if [[ "$cmdline" == *"$PROJECT_DIR"* ]]; then
      kill_tree "$pid" "$script"
      (( killed++ )) || true
      continue
    fi

    # Parent match: this process is a child of a wrapper whose cmdline
    # contains our project directory (e.g. /bin/bash watch-beads.sh spawned
    # by bash -c "cd '/project' && './watch-beads.sh'").
    ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
    if [[ -n "$ppid" && "$ppid" != "1" ]]; then
      parent_cmdline=$(ps -p "$ppid" -o args= 2>/dev/null || true)
      if [[ "$parent_cmdline" == *"$PROJECT_DIR"* ]]; then
        log "PID $pid ($script) matched via parent PID $ppid"
        kill_tree "$pid" "$script"
        (( killed++ )) || true
        continue
      fi
    fi

    log "Skipping PID $pid ($script) — belongs to different project"
    log "  cmdline: $cmdline"
  done
done

# Give processes a moment to handle SIGTERM and exit cleanly.
# This ensures Zellij sees the process exit and can close the pane
# before this script (and the Stop hook) finishes.
if [[ $killed -gt 0 ]]; then
  sleep 0.5
fi

log "Done — sent SIGTERM to $killed process(es)."
exit 0
