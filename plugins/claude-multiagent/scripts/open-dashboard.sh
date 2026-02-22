#!/usr/bin/env bash
# Open Zellij dashboard panes for beads (tickets) and deploy watch.
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
#
# IMPORTANT: The script-name fallback also requires PROJECT_DIR to appear on
# the same line.  This prevents a pane from a *different* project (in another
# Zellij tab) from being mistakenly detected as belonging to this project when
# get_focused_tab_layout() returns a superset of panes or stale versions
# without the UUID mechanism are running.
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
  exit 0
fi

# Only open dashboard panes inside a git repository
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

focused_tab=$(get_focused_tab_layout) || exit 0

# --- Multiple Claude sessions detection ---
claude_count=$(count_claude_panes "$focused_tab" "$PROJECT_DIR")
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

# --- Check if worktree pane is disabled ---
worktree_pane_enabled=true
for config_path in \
  "${PROJECT_DIR}/.claude/claude-multiagent.local.md" \
  "${HOME}/.claude/claude-multiagent.local.md"; do
  if [[ -f "$config_path" ]] && grep -q 'worktree_pane:[[:space:]]*disabled' "$config_path" 2>/dev/null; then
    worktree_pane_enabled=false
    break
  fi
done

# --- Detect existing dashboard panes ---
# Uses pane name= attribute, command=, and args for robust detection.
# This catches both new named panes and old unnamed panes from cached
# plugin versions running watch-*.py from any path.
has_beads=$(has_dashboard_pane "$focused_tab" "dashboard-beads" "beads_tui" "$PROJECT_DIR")
has_deploys=$(has_dashboard_pane "$focused_tab" "dashboard-deploys" "watch-deploys.py" "$PROJECT_DIR")
has_worktree_nvim=$(has_dashboard_pane "$focused_tab" "dashboard-worktree-nvim" "worktree-nvim/init.lua" "$PROJECT_DIR")

all_present=true
[[ "$has_beads" -eq 0 ]] && all_present=false
if $deploy_pane_enabled && [[ "$has_deploys" -eq 0 ]]; then
  all_present=false
fi
if $worktree_pane_enabled && [[ "$has_worktree_nvim" -eq 0 ]]; then
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
#   │   Claude     ├────────────────┤
#   │              │  worktree-nvim │
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
  BEADS_TUI_DIR="${SCRIPT_DIR}/beads-tui"
  BDT_ARGS=(--db-path "${PROJECT_DIR}/.beads/beads.db" --bd-path "$(command -v bd)")

  # When running from the plugin cache the git submodule directory is empty.
  # Try the source repo's copy of the submodule as a fallback.
  if [[ ! -d "${BEADS_TUI_DIR}/beads_tui" ]]; then
    # Walk up from SCRIPT_DIR to find the plugin root, then look for the
    # source checkout (e.g. <repo>/plugins/claude-multiagent/scripts/beads-tui).
    _candidate="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$_candidate" ]]; then
      # SCRIPT_DIR is in the cache (not a git repo).  Try the PROJECT_DIR
      # repo which may contain the plugin source as a submodule / subtree.
      _candidate="$(cd "${PROJECT_DIR}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
    fi
    if [[ -n "$_candidate" && -d "${_candidate}/plugins/claude-multiagent/scripts/beads-tui/beads_tui" ]]; then
      BEADS_TUI_DIR="${_candidate}/plugins/claude-multiagent/scripts/beads-tui"
    fi
  fi

  if [[ -d "${BEADS_TUI_DIR}/beads_tui" ]]; then
    # Bundled submodule — run as python module with PYTHONPATH
    # Prefer the venv python (has textual pre-installed) if available
    _bdt_python="python3"
    if [[ -n "${BEADS_TUI_VENV:-}" && -x "${BEADS_TUI_VENV}/bin/python3" ]]; then
      _bdt_python="${BEADS_TUI_VENV}/bin/python3"
    elif [[ -x "${SCRIPT_DIR}/.beads-tui-venv/bin/python3" ]]; then
      _bdt_python="${SCRIPT_DIR}/.beads-tui-venv/bin/python3"
    fi
    zellij action new-pane --name "dashboard-beads-${DASH_ID}" --close-on-exit --direction right \
      -- env PYTHONPATH="${BEADS_TUI_DIR}" "$_bdt_python" -m beads_tui "${BDT_ARGS[@]}" 2>/dev/null || true
  elif command -v bdt &>/dev/null; then
    # System-installed bdt — use full resolved path so Zellij can find it
    BDT_PATH="$(command -v bdt)"
    zellij action new-pane --name "dashboard-beads-${DASH_ID}" --close-on-exit --direction right \
      -- "$BDT_PATH" "${BDT_ARGS[@]}" 2>/dev/null || true
  else
    # Neither available — show placeholder with install instructions
    zellij action new-pane --name "dashboard-beads-${DASH_ID}" --close-on-exit --direction right \
      -- bash -c 'echo ""; echo "  beads-tui (bdt) is not installed."; echo ""; echo "  Install it with:"; echo "    pipx install beads-tui"; echo ""; echo "  Press Enter to close this pane."; read' 2>/dev/null || true
  fi
fi

# Pre-bootstrap lazy.nvim plugins for the worktree-nvim pane.
# On first run, lazy.nvim clones itself but the actual plugins (diffview.nvim,
# plenary.nvim, nvim-web-devicons) require a network fetch that fails inside
# Zellij panes. Run a headless nvim to install them before opening the pane.
if $worktree_pane_enabled && [[ "$has_worktree_nvim" -eq 0 ]]; then
  NVIM_INIT="${SCRIPT_DIR}/worktree-nvim/init.lua"
  if command -v nvim &>/dev/null && [[ -f "$NVIM_INIT" ]]; then
    _diffview_dir="${HOME}/.local/share/claude-worktree-nvim/lazy/diffview.nvim"
    if [[ ! -d "$_diffview_dir" ]]; then
      timeout 30 nvim --headless -u "${NVIM_INIT}" --clean -c "Lazy! sync" -c "qa!" 2>/dev/null || true
    fi
  fi
fi

# The remaining panes split the right column downward; launch them in parallel.
# If beads already occupies the right column, agents/deploys split it downward.
# If beads is absent, the FIRST new pane must create the right column itself.
{
  # Track whether a right-side pane exists.  If beads was missing we just
  # created it in the foreground block above, so a right pane now exists
  # regardless of the original detection value.
  has_right_pane=1

  if $worktree_pane_enabled && [[ "$has_worktree_nvim" -eq 0 ]]; then
    NVIM_INIT="${SCRIPT_DIR}/worktree-nvim/init.lua"
    if command -v nvim &>/dev/null && [[ -f "$NVIM_INIT" ]]; then
      zellij action move-focus right 2>/dev/null || true
      zellij action move-focus down 2>/dev/null || true
      zellij action new-pane --name "dashboard-worktree-nvim-${DASH_ID}" --close-on-exit --direction down \
        -- nvim -u "${NVIM_INIT}" --clean \
           -c "cd ${PROJECT_DIR}" 2>/dev/null || true
    else
      # Placeholder with install instructions
      zellij action move-focus right 2>/dev/null || true
      zellij action move-focus down 2>/dev/null || true
      zellij action new-pane --name "dashboard-worktree-nvim-${DASH_ID}" --close-on-exit --direction down \
        -- bash -c 'echo ""; echo "  Worktree viewer requires neovim."; echo ""; echo "  Install: brew install neovim"; echo ""; echo "  Press Enter to close."; read' 2>/dev/null || true
    fi
  fi

  if $deploy_pane_enabled && [[ "$has_deploys" -eq 0 ]]; then
    if [[ "$has_right_pane" -eq 1 ]]; then
      # Right column exists — move to the bottom-most pane and split downward.
      zellij action move-focus right 2>/dev/null || true
      zellij action move-focus down 2>/dev/null || true
      zellij action move-focus down 2>/dev/null || true
      zellij action new-pane --name "dashboard-deploys-${DASH_ID}" --close-on-exit --direction down \
        -- python3 "${SCRIPT_DIR}/watch-deploys.py" "${PROJECT_DIR}" "${DASH_ID}" 2>/dev/null || true
    else
      # No right column yet — create deploys to the right of Claude.
      zellij action new-pane --name "dashboard-deploys-${DASH_ID}" --close-on-exit --direction right \
        -- python3 "${SCRIPT_DIR}/watch-deploys.py" "${PROJECT_DIR}" "${DASH_ID}" 2>/dev/null || true
    fi
  fi

  # Return focus to the original (left) pane where Claude runs
  zellij action move-focus left 2>/dev/null || true
} &
# No wait — let agents+deploys panes finish in the background while the
# session-start hook continues to produce its JSON output.
