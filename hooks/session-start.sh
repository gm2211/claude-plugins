#!/usr/bin/env bash
# SessionStart hook for agentic-claude plugin

set -euo pipefail

# Determine plugin root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Read coordinator-role skill content
coordinator_content=$(cat "${PLUGIN_ROOT}/skills/coordinator-role/SKILL.md" 2>&1 || echo "Error reading coordinator-role skill")

# Escape string for JSON embedding using bash parameter substitution.
escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

coordinator_escaped=$(escape_for_json "$coordinator_content")

# Output context injection as JSON
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<EXTREMELY_IMPORTANT>\nYou are running with the agentic-claude plugin.\n\n**Below is the full content of your 'agentic-claude:coordinator-role' skill. For the dashboard skill, use the 'Skill' tool:**\n\n${coordinator_escaped}\n</EXTREMELY_IMPORTANT>"
  }
}
EOF

exit 0
