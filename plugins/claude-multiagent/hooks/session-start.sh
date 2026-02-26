#!/usr/bin/env bash
# SessionStart hook for claude-multiagent plugin

set -euo pipefail

# Determine plugin root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Ensure beads-tui submodule and venv are ready ---
BEADS_TUI_DIR="${PLUGIN_ROOT}/scripts/beads-tui"
BEADS_TUI_VENV="${PLUGIN_ROOT}/scripts/.beads-tui-venv"

# Initialize git submodule if empty (only works in source checkout, not cache)
if [[ ! -d "${BEADS_TUI_DIR}/beads_tui" ]]; then
  _repo_root="$(cd "${PLUGIN_ROOT}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$_repo_root" ]]; then
    git -C "$_repo_root" submodule update --init plugins/claude-multiagent/scripts/beads-tui 2>/dev/null || true
  fi
fi

# Create venv with textual if it doesn't exist (or is broken)
# Requires Python >=3.11 (beads-tui uses 3.10+ syntax like str | None)
if [[ ! -x "${BEADS_TUI_VENV}/bin/python3" ]] || ! "${BEADS_TUI_VENV}/bin/python3" -c "import textual" 2>/dev/null; then
  # Find a suitable Python >=3.11
  _py=""
  for _candidate_py in python3.13 python3.12 python3.11 python3; do
    if command -v "$_candidate_py" &>/dev/null; then
      _ver=$("$_candidate_py" -c "import sys; print(sys.version_info >= (3,11))" 2>/dev/null || echo "False")
      if [[ "$_ver" == "True" ]]; then
        _py="$(command -v "$_candidate_py")"
        break
      fi
    fi
  done
  # Also check common framework paths
  if [[ -z "$_py" ]]; then
    for _fwk in /Library/Frameworks/Python.framework/Versions/3.*/bin/python3; do
      if [[ -x "$_fwk" ]]; then
        _ver=$("$_fwk" -c "import sys; print(sys.version_info >= (3,11))" 2>/dev/null || echo "False")
        if [[ "$_ver" == "True" ]]; then _py="$_fwk"; break; fi
      fi
    done
  fi
  if [[ -n "$_py" ]]; then
    "$_py" -m venv "${BEADS_TUI_VENV}" 2>/dev/null || true
    if [[ -x "${BEADS_TUI_VENV}/bin/pip" ]]; then
      "${BEADS_TUI_VENV}/bin/pip" install --quiet textual 2>/dev/null || true
    fi
  fi
fi

# Export for open-dashboard.sh to use
export BEADS_TUI_VENV

# --- Cache staleness detection (plugin developers only) ---
CACHE_STALE_WARNING=""
if [[ -d "${PWD}/plugins/claude-multiagent" ]]; then
  _source_sha="$(git -C "$PWD" rev-parse HEAD 2>/dev/null || true)"
  _installed_json="${HOME}/.claude/plugins/installed_plugins.json"
  _cached_sha=""
  if [[ -n "$_source_sha" && -f "$_installed_json" ]] && command -v jq &>/dev/null; then
    _cached_sha=$(jq -r '."claude-multiagent@gm2211-plugins"[0].gitCommitSha // empty' "$_installed_json" 2>/dev/null || true)
  fi
  if [[ -n "$_source_sha" && -n "$_cached_sha" && "$_source_sha" != "$_cached_sha" ]]; then
    _cached_version=$(jq -r '."claude-multiagent@gm2211-plugins"[0].version // "unknown"' "$_installed_json" 2>/dev/null || true)
    CACHE_STALE_WARNING="⚠️ PLUGIN CACHE IS STALE — source HEAD (${_source_sha:0:8}) ≠ cached version $_cached_version (${_cached_sha:0:8}). Dashboard scripts and hooks may be outdated. To refresh: rm -rf ~/.claude/plugins/cache/gm2211-plugins/claude-multiagent/ && restart Claude Code session."
  fi
fi

# --- Cache staleness detection (end-user / marketplace install) ---
# Only runs when the developer check above did not set a warning (i.e. the user
# is not running from the plugin's own git repo checkout).
_installed_json="${HOME}/.claude/plugins/installed_plugins.json"
if [[ -z "$CACHE_STALE_WARNING" ]] && [[ -f "$_installed_json" ]] && command -v jq &>/dev/null && command -v gh &>/dev/null; then
  _version_cache="/tmp/claude-multiagent-version-check"
  _fetch_latest=true

  # Skip GitHub API call if cache file is fresher than 1 hour
  if [[ -f "$_version_cache" ]]; then
    _cache_age=$(( $(date +%s) - $(date -r "$_version_cache" +%s 2>/dev/null || echo 0) ))
    if [[ "$_cache_age" -lt 3600 ]]; then
      _fetch_latest=false
    fi
  fi

  if [[ "$_fetch_latest" == "true" ]]; then
    # Fetch latest version from GitHub with a 5-second timeout; fail silently
    _latest_version=$(timeout 5 gh api repos/gm2211/claude-plugins/contents/.claude-plugin/marketplace.json --jq '.content' 2>/dev/null \
      | base64 -d 2>/dev/null \
      | jq -r '.plugins[0].version // empty' 2>/dev/null \
      || true)
    if [[ -n "$_latest_version" ]]; then
      printf '%s' "$_latest_version" > "$_version_cache" 2>/dev/null || true
    fi
  else
    _latest_version=$(cat "$_version_cache" 2>/dev/null || true)
  fi

  _installed_version=$(jq -r '."claude-multiagent@gm2211-plugins"[0].version // empty' "$_installed_json" 2>/dev/null || true)

  if [[ -n "$_installed_version" && -n "$_latest_version" && "$_installed_version" != "$_latest_version" ]]; then
    CACHE_STALE_WARNING="⚠️ PLUGIN UPDATE AVAILABLE — installed version ${_installed_version} but latest is ${_latest_version}. To update: rm -rf ~/.claude/plugins/cache/gm2211-plugins/claude-multiagent/ && restart Claude Code session."
  fi
fi

# Escape string for JSON embedding.
# Uses jq when available; falls back to pure-bash substitution.
if command -v jq &>/dev/null; then
  escape_for_json() {
    jq -Rs . <<< "$1" | sed 's/^"//;s/"$//'
  }
else
  escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
  }
fi

# --- Detect missing permissions in .claude/settings.local.json ---
SETTINGS_FILE="${PWD}/.claude/settings.local.json"
PERMISSIONS_MISSING=""

if [[ ! -f "$SETTINGS_FILE" ]]; then
  PERMISSIONS_MISSING="File ${SETTINGS_FILE} does not exist. All required settings are missing: sandbox.enabled, sandbox.autoAllowBashIfSandboxed, permissions.allow (Read, Edit, Write, Bash(bd:*), Bash(git:*)), env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS."
elif command -v jq &>/dev/null; then
  _missing_parts=()

  # Check sandbox.enabled
  if ! jq -e '.sandbox.enabled == true' "$SETTINGS_FILE" &>/dev/null; then
    _missing_parts+=("sandbox.enabled must be true")
  fi

  # Check sandbox.autoAllowBashIfSandboxed
  if ! jq -e '.sandbox.autoAllowBashIfSandboxed == true' "$SETTINGS_FILE" &>/dev/null; then
    _missing_parts+=("sandbox.autoAllowBashIfSandboxed must be true")
  fi

  # Check each required permissions.allow entry
  for _perm in "Read" "Edit" "Write" 'Bash(bd:*)' 'Bash(git:*)'; do
    if ! jq -e --arg p "$_perm" '.permissions.allow // [] | index($p) != null' "$SETTINGS_FILE" &>/dev/null; then
      _missing_parts+=("permissions.allow missing \"${_perm}\"")
    fi
  done

  # Check env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
  if ! jq -e '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1"' "$SETTINGS_FILE" &>/dev/null; then
    _missing_parts+=("env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS must be \"1\"")
  fi

  # Build human-readable summary
  if [[ ${#_missing_parts[@]} -gt 0 ]]; then
    PERMISSIONS_MISSING=$(printf '%s\n' "${_missing_parts[@]}")
  fi
else
  # jq not available — skip detailed permission checks, flag the dependency
  PERMISSIONS_MISSING="jq is not installed. Install it (e.g. brew install jq) for automatic permission validation. Cannot verify settings in ${SETTINGS_FILE}."
fi

# Build PERMISSIONS_BOOTSTRAP block for additionalContext if anything is missing
PERMISSIONS_BOOTSTRAP=""
if [[ -n "$PERMISSIONS_MISSING" ]]; then
  _bootstrap_block="<PERMISSIONS_BOOTSTRAP>
The following settings are missing or incorrect in ${SETTINGS_FILE}:

${PERMISSIONS_MISSING}

Recommended settings template (merge with any existing settings):

{
  \"permissions\": {
    \"allow\": [\"Read\", \"Edit\", \"Write\", \"Bash(bd:*)\", \"Bash(git:*)\"]
  },
  \"sandbox\": {
    \"enabled\": true,
    \"autoAllowBashIfSandboxed\": true
  },
  \"env\": {
    \"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\": \"1\"
  }
}

Follow the Permissions Bootstrap procedure in your skill specification.
</PERMISSIONS_BOOTSTRAP>"
  PERMISSIONS_BOOTSTRAP="$(escape_for_json "$_bootstrap_block")\n"
fi

# --- Detect worktree state ---
WORKTREE_CONTEXT=""
if git rev-parse --is-inside-work-tree &>/dev/null; then
  GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
  COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null)
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

  if [[ "$GIT_DIR" != "$COMMON_DIR" ]]; then
    # Already in a worktree — note it, no action needed
    WORKTREE_CONTEXT="<WORKTREE_STATE>in_worktree|branch=${CURRENT_BRANCH}|repo_root=${REPO_ROOT}</WORKTREE_STATE>"
  elif [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" || "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    # On default branch — list existing epic and task worktrees
    EXISTING_EPICS=$(ls -d "${REPO_ROOT}/.worktrees/"*/ 2>/dev/null | sed "s|${REPO_ROOT}/.worktrees/||;s|/||" | { grep -v -- '--' || true; }) || true
    EXISTING_TASKS=$(ls -d "${REPO_ROOT}/.worktrees/"*/ 2>/dev/null | sed "s|${REPO_ROOT}/.worktrees/||;s|/||" | { grep -- '--' || true; } | tr '\n' ',' | sed 's/,$//') || true
    EXISTING_EPICS_CSV=$(printf '%s' "$EXISTING_EPICS" | tr '\n' ',' | sed 's/,$//') || true

    # Build the WORKTREE_GUARD block
    _guard_lines="<WORKTREE_GUARD>"$'\n'
    _guard_lines+="⛔ You are on the main branch. The coordinator MUST NOT proceed with any work from main."$'\n'$'\n'

    if [[ -n "$EXISTING_EPICS" ]]; then
      _guard_lines+="Existing epic worktrees:"$'\n'
      while IFS= read -r _epic; do
        [[ -z "$_epic" ]] && continue
        _epic_path="${REPO_ROOT}/.worktrees/${_epic}"
        _epic_branch=$(git -C "$_epic_path" branch --show-current 2>/dev/null || echo "$_epic")
        _guard_lines+="  - ${_epic} (branch: ${_epic_branch}) → cd ${_epic_path} && claude"$'\n'
      done <<< "$EXISTING_EPICS"
      _guard_lines+=$'\n'
    else
      _guard_lines+="No epic worktrees exist yet."$'\n'$'\n'
    fi

    _guard_lines+="How to get into a worktree (tell the user, in this order of preference):"$'\n'$'\n'
    _guard_lines+="  1. Exit and run \`claude\` — the shell function will handle worktree selection automatically."$'\n'
    _guard_lines+="     (If no worktrees exist, it falls back to \`wt new\` and prompts for a description.)"$'\n'$'\n'
    _guard_lines+="  2. Or: run \`wt\` to interactively select an existing worktree, then run \`claude\` from inside it."$'\n'
    _guard_lines+="     To create a new worktree instead: \`wt new\`"$'\n'$'\n'
    _guard_lines+="  3. If the shell functions are not sourced yet:"$'\n'
    _guard_lines+="       source /path/to/shell-configs/zsh-functions/functions.zsh"$'\n'
    _guard_lines+="     (replace /path/to with the actual clone location of claude-plugins)"$'\n'$'\n'
    _guard_lines+="  4. Last resort — raw git commands (use only if shell functions are unavailable):"$'\n'
    _guard_lines+="       git worktree add ${REPO_ROOT}/.worktrees/<name> -b <name>"$'\n'
    _guard_lines+="       cd ${REPO_ROOT}/.worktrees/<name>"$'\n'
    _guard_lines+="       claude"$'\n'$'\n'
    _guard_lines+="ACTION REQUIRED: Tell the user to exit this session and restart Claude from a worktree directory. Do NOT proceed with any feature work, code changes, or agent dispatch."$'\n'
    _guard_lines+="</WORKTREE_GUARD>"

    WORKTREE_CONTEXT="${_guard_lines}"$'\n'
    WORKTREE_CONTEXT+="<WORKTREE_SETUP>on_default_branch|default=${DEFAULT_BRANCH}|epics=${EXISTING_EPICS_CSV}|tasks=${EXISTING_TASKS}|repo_root=${REPO_ROOT}</WORKTREE_SETUP>"
  fi
fi

WORKTREE_CONTEXT_ESCAPED=""
if [[ -n "$WORKTREE_CONTEXT" ]]; then
  WORKTREE_CONTEXT_ESCAPED="$(escape_for_json "$WORKTREE_CONTEXT")\n"
fi

# Read multiagent-coordinator skill content and resolve $PLUGIN_ROOT references
coordinator_content=$(cat "${PLUGIN_ROOT}/skills/multiagent-coordinator/SKILL.md" 2>&1 || echo "Error reading multiagent-coordinator skill")
coordinator_content="${coordinator_content//\$PLUGIN_ROOT/${PLUGIN_ROOT}}"
coordinator_escaped=$(escape_for_json "$coordinator_content")

# Open Zellij dashboard panes (shared script; captures output to avoid
# breaking JSON on stdout). Any warnings (e.g. multi-session) are stored
# and relayed to the model via additionalContext.
dashboard_output=$("${PLUGIN_ROOT}/scripts/open-dashboard.sh" "${PWD}" 2>&1) || true

# Build the dashboard status note for the model
dashboard_note="The Zellij dashboard panes are already open."
if [[ -n "$dashboard_output" ]]; then
  dashboard_note="Dashboard script output: ${dashboard_output}"
fi
dashboard_note_escaped=$(escape_for_json "$dashboard_note")

# Prepend cache staleness warning if detected
CACHE_STALE_ESCAPED=""
if [[ -n "$CACHE_STALE_WARNING" ]]; then
  CACHE_STALE_ESCAPED="$(escape_for_json "$CACHE_STALE_WARNING")\n\n"
fi

# Output context injection as JSON
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${CACHE_STALE_ESCAPED}${PERMISSIONS_BOOTSTRAP}${WORKTREE_CONTEXT_ESCAPED}<EXTREMELY_IMPORTANT>\nYou are a COORDINATOR (claude-multiagent plugin). FORBIDDEN from editing files, writing code, running builds/tests/linters. Only git merges allowed. No exceptions. Dispatch sub-agents for all work. If task feels small, ask user via AskUserQuestion before doing it yourself.\n\nThe following is your complete behavioral specification. Every rule is mandatory.\n\n${coordinator_escaped}\n\n${dashboard_note_escaped}\n\nAcknowledge coordinator mode in your first response.\n</EXTREMELY_IMPORTANT>"
  }
}
EOF

exit 0
