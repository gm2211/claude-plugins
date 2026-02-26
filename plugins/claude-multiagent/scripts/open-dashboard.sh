#!/usr/bin/env bash
# Open Zellij dashboard panes for beads (tickets) and deploy watch.
# Called by both the SessionStart hook and the agents-dashboard skill.
# Fails silently when not running inside Zellij.
#
# Features:
# - Detects existing dashboard panes and only creates missing ones
# - Detects multiple Claude sessions in the same tab and warns instead of
#   opening duplicate panes
# - Skips beads and/or dashboard panes if disabled in settings.local.json
#   (set "panes": {"beads": false} or "panes": {"dashboard": false} in
#    .claude/settings.local.json)
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
  layout=$(timeout 5 zellij action dump-layout 2>/dev/null) || return 1

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
#
# IMPORTANT: The script-name fallback also requires PROJECT_DIR to appear on
# the same line.  This prevents a pane from a *different* project (in another
# Zellij tab) from being mistakenly detected as belonging to this project when
# get_focused_tab_layout() returns a superset of panes or stale versions
# without the UUID mechanism are running.
# Filter out pane blocks that contain "start_suspended true" from the layout.
# Zellij saved layouts preserve these as stale artifacts; they are not live panes.
strip_suspended_panes() {
  local layout="$1"
  local result=""
  local pane_block=""
  local in_pane=0
  local depth=0

  while IFS= read -r line; do
    if [[ $in_pane -eq 0 ]]; then
      if [[ "$line" =~ ^[[:space:]]*pane[[:space:]] && "$line" == *"{"* ]]; then
        in_pane=1
        depth=1
        pane_block="$line"$'\n'
      else
        result+="$line"$'\n'
      fi
    else
      pane_block+="$line"$'\n'
      local opens="${line//[^\{]/}"
      local closes="${line//[^\}]/}"
      depth=$(( depth + ${#opens} - ${#closes} ))
      if [[ $depth -le 0 ]]; then
        # Pane block complete — keep it only if not suspended
        if [[ "$pane_block" != *"start_suspended true"* ]]; then
          result+="$pane_block"
        fi
        pane_block=""
        in_pane=0
        depth=0
      fi
    fi
  done <<< "$layout"

  printf '%s' "$result"
}

has_dashboard_pane() {
  local layout="$1"
  local pane_name="$2"    # e.g. "dashboard-beads"
  local script_name="$3"  # e.g. "watch-beads.py"
  local project_dir="$4"  # e.g. "/Users/me/my-project" (used to scope script-name fallback)
  while IFS= read -r line; do
    # Match by pane name attribute: name="dashboard-beads"
    # Named panes include a DASH_ID suffix (e.g. dashboard-beads-abc12345) and
    # are already scoped to the focused tab, so no project-dir check needed.
    if [[ "$line" == *"name=\"${pane_name}"* ]]; then
      echo 1
      return
    fi
    # Match by script basename in command= (e.g. command="/path/to/watch-beads.py")
    # Require PROJECT_DIR on the same line to avoid matching panes from other projects.
    if [[ "$line" == *"command="* && "$line" == *"$script_name"* && "$line" == *"$project_dir"* ]]; then
      echo 1
      return
    fi
    # Match by script basename in args (any format: args "/path/watch-beads.py" ...)
    # This catches panes created without --name from any path.
    # Require PROJECT_DIR on the same line to avoid matching panes from other projects.
    if [[ "$line" == *"args"* && "$line" == *"$script_name"* && "$line" == *"$project_dir"* ]]; then
      echo 1
      return
    fi
  done <<< "$layout"
  echo 0
}

# Count how many panes in the layout run the "claude" command AND whose
# working directory matches PROJECT_DIR.  We cross-reference the layout
# with the actual process list so that dead/stale Claude panes with
# different CWDs don't inflate the count and block new session setup.
count_claude_panes() {
  local layout="$1"
  local project_dir="$2"
  local count=0

  # Collect PIDs of running claude processes whose cwd == project_dir.
  local matching_pids=()
  local pids
  pids=$(pgrep -x claude 2>/dev/null || pgrep -f 'claude' 2>/dev/null || true)
  for pid in $pids; do
    local cwd
    cwd=$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//' || true)
    if [[ "$cwd" == "$project_dir" ]]; then
      matching_pids+=("$pid")
    fi
  done

  # If we found at least one live claude process for this project, count
  # command="claude" lines in the layout as a proxy for session count.
  # (The layout doesn't expose PIDs, so we use the live-process check
  # as the ground truth and cap the count at the number of live sessions.)
  if [[ ${#matching_pids[@]} -gt 0 ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ command=\"claude\" ]]; then
        (( count++ ))
      fi
    done <<< "$layout"
    # Don't report more sessions than we actually found live
    if [[ $count -gt ${#matching_pids[@]} ]]; then
      count=${#matching_pids[@]}
    fi
  fi

  echo "$count"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# If not inside Zellij, bail silently
if [[ -z "${ZELLIJ:-}" ]]; then
  echo "SKIPPED:not_in_zellij"
  exit 0
fi

# Only open dashboard panes inside a git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "SKIPPED:not_git_repo"
  exit 0
fi

if ! focused_tab=$(get_focused_tab_layout); then
  echo "FAILED:dump_layout_timeout_or_error"
  exit 0
fi

# Strip Zellij saved-layout artifacts (start_suspended panes) so they don't
# cause false-positive detections of existing dashboard panes.
focused_tab=$(strip_suspended_panes "$focused_tab")

# --- Multiple Claude sessions detection ---
claude_count=$(count_claude_panes "$focused_tab" "$PROJECT_DIR")
if [[ "$claude_count" -gt 1 ]]; then
  # Another Claude instance already has dashboard panes in this tab.
  echo "SKIPPED:multi_session — another Claude session is already running in this Zellij tab. Start this session in a different Zellij tab for the full dashboard experience."
  exit 0
fi

# --- Check which panes are disabled ---
# Pane toggles are stored in .claude/settings.local.json under the "panes" key:
#   { "panes": { "beads": true, "dashboard": true } }
# Set a pane to false to disable it.  Missing keys default to enabled.
# Both project-level and home-level settings files are checked.
# Legacy: .claude/claude-multiagent.local.md keys (beads_pane/dashboard_pane/
# deploy_pane: disabled) are also honoured as a fallback.
beads_pane_enabled=true
dashboard_pane_enabled=true

# Helper: read a pane toggle from settings.local.json via jq.
# Usage: _pane_enabled <json-file> <pane-name>
# Returns "false" if the pane is explicitly disabled, empty otherwise.
_pane_disabled_in_json() {
  local json_file="$1" pane_name="$2"
  if [[ -f "$json_file" ]] && command -v jq &>/dev/null; then
    # .panes.<name> == false  →  output "disabled"
    if jq -e --arg p "$pane_name" '.panes[$p] == false' "$json_file" &>/dev/null; then
      echo "disabled"
    fi
  fi
}

for config_dir in "${PROJECT_DIR}/.claude" "${HOME}/.claude"; do
  # Primary: settings.local.json
  _settings="${config_dir}/settings.local.json"
  if [[ "$(_pane_disabled_in_json "$_settings" "beads")" == "disabled" ]]; then
    beads_pane_enabled=false
  fi
  if [[ "$(_pane_disabled_in_json "$_settings" "dashboard")" == "disabled" ]]; then
    dashboard_pane_enabled=false
  fi

  # Legacy fallback: claude-multiagent.local.md
  _legacy="${config_dir}/claude-multiagent.local.md"
  if [[ -f "$_legacy" ]]; then
    if grep -q 'beads_pane:[[:space:]]*disabled' "$_legacy" 2>/dev/null; then
      beads_pane_enabled=false
    fi
    if grep -q 'dashboard_pane:[[:space:]]*disabled' "$_legacy" 2>/dev/null; then
      dashboard_pane_enabled=false
    fi
    if grep -q 'deploy_pane:[[:space:]]*disabled' "$_legacy" 2>/dev/null; then
      dashboard_pane_enabled=false
    fi
  fi
done

# Log disabled panes so users can see why panes are missing
if ! $beads_pane_enabled; then
  echo "Beads pane disabled. Set \"panes\": {\"beads\": true} in .claude/settings.local.json to re-enable."
fi
if ! $dashboard_pane_enabled; then
  echo "Dashboard pane disabled. Set \"panes\": {\"dashboard\": true} in .claude/settings.local.json to re-enable."
fi

# --- Detect existing dashboard panes ---
# Uses pane name= attribute, command=, and args for robust detection.
# This catches both new named panes and old unnamed panes from cached
# plugin versions running watch-*.py from any path.
has_beads=$(has_dashboard_pane "$focused_tab" "dashboard-beads" "beads_tui" "$PROJECT_DIR")
has_dashboard=$(has_dashboard_pane "$focused_tab" "dashboard-watch" "watch_dashboard" "$PROJECT_DIR")
# Legacy detection for old separate panes (watch-deploys.py / watch-gh-actions.py).
# Safe to remove next version — only needed while users may still have old sessions.
has_deploys=$(has_dashboard_pane "$focused_tab" "dashboard-deploys" "watch-deploys.py" "$PROJECT_DIR")
has_ghactions=$(has_dashboard_pane "$focused_tab" "dashboard-ghactions" "watch-gh-actions.py" "$PROJECT_DIR")
# Treat legacy panes as equivalent to the new unified dashboard
if [[ "$has_deploys" -eq 1 ]] || [[ "$has_ghactions" -eq 1 ]]; then
  has_dashboard=1
fi

all_present=true
if $beads_pane_enabled && [[ "$has_beads" -eq 0 ]]; then
  all_present=false
fi
if $dashboard_pane_enabled && [[ "$has_dashboard" -eq 0 ]]; then
  all_present=false
fi

if $all_present; then
  # All expected panes already exist -- nothing to do
  echo "PANES_EXIST"
  exit 0
fi

# Generate a unique dashboard instance ID so close-dashboard.sh can kill
# only the processes belonging to THIS tab's dashboard panes.
DASH_ID=$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | head -c 8)

# Open missing panes. The target layout has dashboard panes on the RIGHT side:
#
#   ┌──────────────────┬──────────────────┐
#   │                  │   beads-tui      │
#   │     Claude       ├──────────────────┤
#   │                  │  watch-dashboard │
#   └──────────────────┴──────────────────┘
#
# new-pane moves focus to the newly created pane, so we track where
# focus ends up after each step.

if $beads_pane_enabled && [[ "$has_beads" -eq 0 ]]; then
  # Create beads pane to the right of Claude. Focus moves to beads.
  BEADS_TUI_DIR="${SCRIPT_DIR}/beads-tui"
  _bd_path="$(command -v bd 2>/dev/null || true)"
  # Resolve db path through git to the main repo root so worktrees find the
  # actual Dolt database (which lives at <main-repo>/.beads/dolt, not in the
  # worktree directory).
  _repo_root="$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null)" || _repo_root="$PROJECT_DIR"
  BDT_ARGS=(--db-path "${_repo_root}/.beads/dolt")
  [[ -n "$_bd_path" ]] && BDT_ARGS+=(--bd-path "$_bd_path")

  # When running from the plugin cache, run.sh and .venv may be missing even
  # when beads_tui/ source exists.  Fall back to the source repo's copy.
  if [[ ! -x "${BEADS_TUI_DIR}/run.sh" ]]; then
    # Walk up from SCRIPT_DIR to find the plugin root, then look for the
    # source checkout (e.g. <repo>/plugins/claude-multiagent/scripts/beads-tui).
    _candidate="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$_candidate" ]]; then
      # SCRIPT_DIR is in the cache (not a git repo).  Try the PROJECT_DIR
      # repo which may contain the plugin source as a submodule / subtree.
      _candidate="$(cd "${PROJECT_DIR}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
    fi
    if [[ -n "$_candidate" && -x "${_candidate}/plugins/claude-multiagent/scripts/beads-tui/run.sh" ]]; then
      BEADS_TUI_DIR="${_candidate}/plugins/claude-multiagent/scripts/beads-tui"
    fi
  fi

  # Priority 1: Plugin-managed venv (portable, created by session-start.sh)
  _managed_venv="${BEADS_TUI_VENV:-${SCRIPT_DIR}/.beads-tui-venv}"
  if [[ -x "${_managed_venv}/bin/python3" ]] && "${_managed_venv}/bin/python3" -c "import textual" 2>/dev/null; then
    zellij action new-pane --name "dashboard-beads-${DASH_ID}" --close-on-exit --direction right \
      -- env PYTHONPATH="${BEADS_TUI_DIR}" "${_managed_venv}/bin/python3" -m beads_tui "${BDT_ARGS[@]}" 2>/dev/null || true
  elif [[ -x "${BEADS_TUI_DIR}/run.sh" ]]; then
    # Developer fallback: submodule's run.sh (may have host-specific venv)
    zellij action new-pane --name "dashboard-beads-${DASH_ID}" --close-on-exit --direction right \
      -- "${BEADS_TUI_DIR}/run.sh" "${BDT_ARGS[@]}" 2>/dev/null || true
  elif command -v bdt &>/dev/null; then
    BDT_PATH="$(command -v bdt)"
    zellij action new-pane --name "dashboard-beads-${DASH_ID}" --close-on-exit --direction right \
      -- "$BDT_PATH" "${BDT_ARGS[@]}" 2>/dev/null || true
  else
    zellij action new-pane --name "dashboard-beads-${DASH_ID}" --close-on-exit --direction right \
      -- bash -c 'echo ""; echo "  beads-tui (bdt) is not installed."; echo ""; echo "  Install it with:"; echo "    pipx install beads-tui"; echo ""; echo "  Press Enter to close this pane."; read' 2>/dev/null || true
  fi
fi

# Signal success — panes are being created (some may launch in background below)
echo "PANES_CREATED"

# Launch watch-dashboard pane (unified deploys + gh-actions) below beads.
# If beads already occupies the right column, the dashboard splits downward.
# If beads is absent, the dashboard creates the right column itself.
{
  if $dashboard_pane_enabled && [[ "$has_dashboard" -eq 0 ]]; then
    # Resolve watch-dashboard directory (same fallback logic as beads-tui)
    WATCH_DASH_DIR="${SCRIPT_DIR}/watch-dashboard"
    if [[ ! -d "${WATCH_DASH_DIR}/watch_dashboard" ]]; then
      _candidate="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
      if [[ -z "$_candidate" ]]; then
        _candidate="$(cd "${PROJECT_DIR}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
      fi
      if [[ -n "$_candidate" && -d "${_candidate}/plugins/claude-multiagent/scripts/watch-dashboard/watch_dashboard" ]]; then
        WATCH_DASH_DIR="${_candidate}/plugins/claude-multiagent/scripts/watch-dashboard"
      fi
    fi

    # A right pane now exists (beads was just created above).
    # Move to the bottom-most right pane and split downward.
    zellij action move-focus right 2>/dev/null || true
    zellij action move-focus down 2>/dev/null || true
    zellij action move-focus down 2>/dev/null || true

    _managed_venv="${BEADS_TUI_VENV:-${SCRIPT_DIR}/.beads-tui-venv}"
    if [[ -x "${_managed_venv}/bin/python3" ]] && "${_managed_venv}/bin/python3" -c "import textual" 2>/dev/null; then
      zellij action new-pane --name "dashboard-watch-${DASH_ID}" --close-on-exit --direction down \
        -- env PYTHONPATH="${WATCH_DASH_DIR}:${PYTHONPATH:-}" "${_managed_venv}/bin/python3" -m watch_dashboard \
           --project-dir "${PROJECT_DIR}" --dash-id "${DASH_ID}" 2>/dev/null || true
    elif [[ -x "${WATCH_DASH_DIR}/run.sh" ]]; then
      zellij action new-pane --name "dashboard-watch-${DASH_ID}" --close-on-exit --direction down \
        -- "${WATCH_DASH_DIR}/run.sh" --project-dir "${PROJECT_DIR}" --dash-id "${DASH_ID}" 2>/dev/null || true
    else
      zellij action new-pane --name "dashboard-watch-${DASH_ID}" --close-on-exit --direction down \
        -- bash -c 'echo ""; echo "  watch-dashboard requires textual."; echo "  Ensure BEADS_TUI_VENV is set."; echo ""; echo "  Press Enter to close."; read' 2>/dev/null || true
    fi
  fi

  # Return focus to the original (left) pane where Claude runs
  zellij action move-focus left 2>/dev/null || true
} &
# No wait — let dashboard pane finish in the background while the
# session-start hook continues to produce its JSON output.
