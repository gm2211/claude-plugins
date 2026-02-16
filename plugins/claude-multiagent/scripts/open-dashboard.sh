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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="${1:-$PWD}"

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

# Count how many panes in the layout run a command whose args contain a pattern.
count_panes_with_arg() {
  local layout="$1"
  local pattern="$2"
  local count=0
  while IFS= read -r line; do
    if [[ "$line" == *"args "* && "$line" == *"$pattern"* ]]; then
      (( count++ ))
    fi
  done <<< "$layout"
  echo "$count"
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
has_beads=$(count_panes_with_arg "$focused_tab" "watch-beads.sh")
has_agents=$(count_panes_with_arg "$focused_tab" "watch-agents.sh")
has_deploys=$(count_panes_with_arg "$focused_tab" "watch-deploys.sh")

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

# Open missing panes. When both are missing we create the standard layout
# (beads on the right, agents below beads, deploys below agents).
# When only one is missing we add it in the right direction relative to
# the existing split.

if [[ "$has_beads" -eq 0 ]]; then
  zellij action new-pane --name "dashboard-beads" --direction right \
    -- bash -c "cd '${PROJECT_DIR}' && '${SCRIPT_DIR}/watch-beads.sh'" 2>/dev/null || true
fi

if [[ "$has_agents" -eq 0 ]]; then
  if [[ "$has_beads" -eq 0 ]]; then
    # We just created the beads pane to the right; move focus there
    # so the agents pane opens below it.
    zellij action move-focus right 2>/dev/null || true
  else
    # Beads pane already exists on the right -- move focus there first.
    zellij action move-focus right 2>/dev/null || true
  fi

  zellij action new-pane --name "dashboard-agents" --direction down \
    -- bash -c "cd '${PROJECT_DIR}' && '${SCRIPT_DIR}/watch-agents.sh'" 2>/dev/null || true
fi

if $deploy_pane_enabled && [[ "$has_deploys" -eq 0 ]]; then
  # Deploy pane goes below agents. Move focus down to the agents pane area.
  zellij action move-focus down 2>/dev/null || true

  zellij action new-pane --name "dashboard-deploys" --direction down \
    -- bash -c "cd '${PROJECT_DIR}' && '${SCRIPT_DIR}/watch-deploys.sh'" 2>/dev/null || true
fi

# Return focus to the original (left) pane where Claude runs
zellij action move-focus left 2>/dev/null || true
