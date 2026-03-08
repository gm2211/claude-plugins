#!/usr/bin/env bash
# Launcher script for watch-dashboard.
# Uses the managed venv from BEADS_TUI_VENV (shared with beads-tui).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH_DASHBOARD_DIR="${SCRIPT_DIR}/watch_dashboard"

# Find a Python with textual installed.
# Prefer plugin-managed venv (multiple search paths), then system interpreters.
PYTHON=""

_python_has_textual() {
    local py="$1"
    "$py" -c "import textual" >/dev/null 2>&1
}

# Search order for the managed venv:
# 1. BEADS_TUI_VENV env var (set by session-start.sh)
# 2. Sibling .beads-tui-venv (same scripts/ dir as this file)
# 3. Walk up to find plugin cache venvs (handles marketplace installs)
_venv_candidates=(
    "${BEADS_TUI_VENV:-}"
    "${SCRIPT_DIR}/../.beads-tui-venv"
)
# Search plugin cache paths (marketplace installs)
for _cache_venv in "${HOME}"/.claude/plugins/cache/*/claude-multiagent/*/scripts/.beads-tui-venv; do
    [[ -d "$_cache_venv" ]] && _venv_candidates+=("$_cache_venv")
done

for _venv in "${_venv_candidates[@]}"; do
    [[ -z "$_venv" ]] && continue
    if [[ -x "${_venv}/bin/python3" ]] && _python_has_textual "${_venv}/bin/python3"; then
        PYTHON="${_venv}/bin/python3"
        break
    fi
done

# Fallback: system python with textual
if [[ -z "$PYTHON" ]]; then
    for candidate in python3.13 python3.12 python3.11 python3; do
        if command -v "$candidate" &>/dev/null && _python_has_textual "$candidate"; then
            PYTHON="$candidate"
            break
        fi
    done
fi

if [[ -z "$PYTHON" ]]; then
    echo ""
    echo "watch-dashboard could not start (missing Python package: textual)."
    echo ""
    echo "Fix options:"
    echo "  1) Start Claude once so SessionStart can bootstrap the managed venv."
    echo "  2) Or install textual manually: python3 -m pip install textual"
    echo ""
    if [[ -t 0 ]]; then
        echo "Press Enter to close this pane."
        read -r _
    fi
    exit 1
fi

exec env PYTHONPATH="${SCRIPT_DIR}:${PYTHONPATH:-}" "$PYTHON" -m watch_dashboard "$@"
