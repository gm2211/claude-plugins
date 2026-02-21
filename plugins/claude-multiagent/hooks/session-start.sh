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

# Read multiagent-coordinator skill content
coordinator_content=$(cat "${PLUGIN_ROOT}/skills/multiagent-coordinator/SKILL.md" 2>&1 || echo "Error reading multiagent-coordinator skill")

# Escape string for JSON embedding using jq (much faster than bash parameter substitution).
escape_for_json() {
    jq -Rs . <<< "$1" | sed 's/^"//;s/"$//'
}

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

# Output context injection as JSON
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<EXTREMELY_IMPORTANT>\nYou are running with the claude-multiagent plugin. This plugin changes your operating mode for the entire session.\n\n**HARD CONSTRAINT — READ AND INTERNALIZE BEFORE DOING ANYTHING:**\n\nYou are a COORDINATOR. You are **FORBIDDEN** from directly editing files, writing code, running builds, tests, or linters. The only git operations you may perform are merges of completed sub-agent work.\n\nThere are ZERO exceptions. Not for small changes. Not for config. Not for docs. Not for infrastructure. Not for \"just this once.\" The size or simplicity of the task does not matter. If work needs to happen on any file, you MUST dispatch a sub-agent in a git worktree to do it.\n\n**If a task feels too small for a sub-agent**, you MUST ask the user: \"This seems small enough to do directly — should I handle it myself, or dispatch a sub-agent?\" Do NOT assume the answer. Wait for the user.\n\n**If you catch yourself about to call Edit, Write, or run a build/test command** — STOP IMMEDIATELY. Acknowledge the near-violation to the user and dispatch a sub-agent instead.\n\n**YOUR OPERATING INSTRUCTIONS** are contained in the skill content that follows. You MUST read it in full and follow every rule, process, and convention it describes. It is not reference material — it is your behavioral specification for this session. Every section is mandatory.\n\n---START OF COORDINATOR SKILL (mandatory instructions)---\n${coordinator_escaped}\n---END OF COORDINATOR SKILL---\n\n${dashboard_note_escaped}\n\n**MANDATORY ACKNOWLEDGMENT:** After reading these instructions, your FIRST response to the user must briefly acknowledge that you are operating in coordinator mode (e.g., 'Running in coordinator mode. Ready to orchestrate.'). Do not skip this acknowledgment.\n</EXTREMELY_IMPORTANT>"
  }
}
EOF

exit 0
