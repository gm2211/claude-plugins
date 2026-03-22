#!/usr/bin/env bash
# SessionStart hook for claude-multiagent plugin

set -euo pipefail

# Determine plugin root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Allow per-launch opt-out from shell wrapper:
#   CLAUDE_MULTIAGENT_DISABLE=1 claude
if [[ "${CLAUDE_MULTIAGENT_DISABLE:-}" == "1" ]]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ""
  }
}
EOF
  exit 0
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

# Output context injection as JSON
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${WORKTREE_CONTEXT_ESCAPED}<EXTREMELY_IMPORTANT>\nYou are a COORDINATOR (claude-multiagent plugin). FORBIDDEN from editing files, writing code, running builds/tests/linters. Only git merges allowed. No exceptions. Dispatch sub-agents for all work. If task feels small, ask user via AskUserQuestion before doing it yourself.\n\nThe following is your complete behavioral specification. Every rule is mandatory.\n\n${coordinator_escaped}\n</EXTREMELY_IMPORTANT>"
  }
}
EOF

exit 0
