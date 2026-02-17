#!/usr/bin/env bash
# Open Zellij dashboard panes for beads (tickets), agent status, and deploy watch.
# Called by both the SessionStart hook and the agents-dashboard skill.
# Fails silently when not running inside Zellij.
#
# Features:
# - Detects existing dashboard panes and only creates missing ones
# - Detects multiple Claude sessions in the same tab and warns instead of
#   opening duplicate panes
# - Skips deploy pane if disabled in plugin config
# - Uses a lock to prevent concurrent runs from creating duplicate panes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="${1:-$PWD}"

# ---------------------------------------------------------------------------
# Lock — prevent concurrent runs from creating duplicate panes
# ---------------------------------------------------------------------------
# Uses mkdir as an atomic lock. If SessionStart fires multiple times quickly,
# only one instance proceeds; others exit silently.

LOCK_DIR="/tmp/open-dashboard-${ZELLIJ_SESSION_NAME:-$$}.lock"

cleanup_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# Remove stale locks older than 30 seconds (e.g., from a crashed run)
if [[ -d "$LOCK_DIR" ]]; then
  lock_mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
  lock_age=$(( $(date +%s) - lock_mtime ))
  if [[ $lock_age -gt 30 ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Another instance is already running — exit silently
  exit 0
fi
trap cleanup_lock EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Extract the focused tab block from dump-layout output.
# The focused tab contains focus=true in its tab declaration.
get_focused_tab_layout() {
  local layout
  layout=$(zellij action dump-layout 2>/dev/null) || return 1

  local in_focused=0
  local depth=0
  local result=""

  while IFS= read -r line; do
    if [[ $in_focused -eq 0 ]]; then
      # Look for a tab line with focus=true
      if [[ "$line" =~ ^[[:space:]]*tab[[:space:]].*focus=true ]]; then
        in_focused=1
        depth=1
        result="$line"$'\n'
      fi
    else
      result+="$line"$'\n'
      # Track brace depth to find the end of the tab block
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

# Check if a dashboard pane exists by its name attribute OR by its script
# appearing in command= or args lines.  Panes are created with
# --name "dashboard-beads" etc., so checking the name= attribute in the layout
# dump is the primary method.  As a fallback we also match the script basename
# anywhere in command= or args lines, which catches panes created by older
# plugin versions (without --name) running from any path (including the
# plugin cache).
has_dashboard_pane() {
  local layout="$1"
  local pane_name="$2"    # e.g. "dashboard-beads"
  local script_name="$3"  # e.g. "watch-beads.py"
  while IFS= read -r line; do
    # Match by pane name attribute: name="dashboard-beads"
    if [[ "$line" == *"name=\"${pane_name}"* ]]; then
      echo 1
      return
    fi
    # Match by script basename in command= (e.g. command="/path/to/watch-beads.py")
    if [[ "$line" == *"command="* && "$line" == *"$script_name"* ]]; then
      echo 1
      return
    fi
    # Match by script basename in args (any format: args "/path/watch-beads.py" ...)
    # This catches panes created without --name from any path.
    if [[ "$line" == *"args"* && "$line" == *"$script_name"* ]]; then
      echo 1
      return
    fi
  done <<< "$layout"
  echo 0
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# If not inside Zellij, bail silently
if [[ -z "${ZELLIJ:-}" ]]; then
  exit 0
fi

# Only open dashboard panes inside a git repository
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

focused_tab=$(get_focused_tab_layout) || exit 0

# --- Multiple Claude sessions detection ---
claude_count=$(count_claude_panes "$focused_tab")
if [[ "$claude_count" -gt 1 ]]; then
  # Another Claude instance already has dashboard panes in this tab.
  echo "COORDINATOR MODE: DASHBOARD PANES NOT OPENED."
  echo "ANOTHER CLAUDE SESSION IS ALREADY RUNNING IN THIS ZELLIJ TAB."
  echo "START THIS SESSION IN A DIFFERENT ZELLIJ TAB FOR THE FULL DASHBOARD EXPERIENCE."
  exit 0
fi

# --- Check if deploy pane is disabled ---
deploy_pane_enabled=true
for config_path in \
  "${PROJECT_DIR}/.claude/claude-multiagent.local.md" \
  "${HOME}/.claude/claude-multiagent.local.md"; do
  if [[ -f "$config_path" ]] && grep -q 'deploy_pane:[[:space:]]*disabled' "$config_path" 2>/dev/null; then
    deploy_pane_enabled=false
    break
  fi
done

# --- Detect existing dashboard panes ---
# Uses pane name= attribute, command=, and args for robust detection.
# This catches both new named panes and old unnamed panes from cached
# plugin versions running watch-*.py from any path.
has_beads=$(has_dashboard_pane "$focused_tab" "dashboard-beads" "watch-beads.py")
has_agents=$(has_dashboard_pane "$focused_tab" "dashboard-agents" "watch-agents.py")
has_deploys=$(has_dashboard_pane "$focused_tab" "dashboard-deploys" "watch-deploys.py")

all_present=true
[[ "$has_beads" -eq 0 ]] && all_present=false
[[ "$has_agents" -eq 0 ]] && all_present=false
if $deploy_pane_enabled && [[ "$has_deploys" -eq 0 ]]; then
  all_present=false
fi

if $all_present; then
  # All expected panes already exist -- nothing to do
  exit 0
fi

# Generate a unique dashboard instance ID so close-dashboard.sh can kill
# only the processes belonging to THIS tab's dashboard panes.
DASH_ID=$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | head -c 8)

# Open missing panes. The target layout has all three dashboard panes
# stacked vertically on the RIGHT side:
#
#   ┌──────────────┬────────────────┐
#   │              │  watch-beads   │
#   │              ├────────────────┤
#   │   Claude     │  watch-agents  │
#   │              ├────────────────┤
#   │              │  watch-deploys │
#   └──────────────┴────────────────┘
#
# new-pane moves focus to the newly created pane, so we track where
# focus ends up after each step.

# Launch panes in parallel. Each pane creation block runs in a background
# subshell with a small stagger to preserve spatial layout ordering (each
# new-pane is placed relative to the currently focused pane).

if [[ "$has_beads" -eq 0 ]]; then
  # Create beads pane to the right of Claude. Focus moves to beads.
  zellij action new-pane --name "dashboard-beads-${DASH_ID}" --close-on-exit --direction right \
    -- python3 "${SCRIPT_DIR}/watch-beads.py" "${PROJECT_DIR}" "${DASH_ID}" 2>/dev/null || true
fi

# The remaining panes split the right column downward; launch them in parallel.
{
  if [[ "$has_agents" -eq 0 ]]; then
    # Ensure focus is on the right side (beads) before splitting downward.
    zellij action move-focus right 2>/dev/null || true

    zellij action new-pane --name "dashboard-agents-${DASH_ID}" --close-on-exit --direction down \
      -- python3 "${SCRIPT_DIR}/watch-agents.py" "${PROJECT_DIR}" "${DASH_ID}" 2>/dev/null || true
    # Focus is now on the agents pane.
  fi

  if $deploy_pane_enabled && [[ "$has_deploys" -eq 0 ]]; then
    # Ensure focus is on the right side, then move to the bottom-most pane
    # so deploys is created below agents (not below Claude).
    zellij action move-focus right 2>/dev/null || true
    zellij action move-focus down 2>/dev/null || true
    zellij action move-focus down 2>/dev/null || true

    zellij action new-pane --name "dashboard-deploys-${DASH_ID}" --close-on-exit --direction down \
      -- python3 "${SCRIPT_DIR}/watch-deploys.py" "${PROJECT_DIR}" "${DASH_ID}" 2>/dev/null || true
  fi

  # Return focus to the original (left) pane where Claude runs
  zellij action move-focus left 2>/dev/null || true
} &
# No wait — let agents+deploys panes finish in the background while the
# session-start hook continues to produce its JSON output.
