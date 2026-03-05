#!/usr/bin/env bash
# Launcher script for watch-dashboard.
# Uses the managed venv from BEADS_TUI_VENV (shared with beads-tui).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH_DASHBOARD_DIR="${SCRIPT_DIR}/watch_dashboard"

# Find a Python with textual installed.
# Prefer plugin-managed venv, then known local interpreters.
_venv="${BEADS_TUI_VENV:-${SCRIPT_DIR}/../.beads-tui-venv}"
PYTHON=""

_python_has_textual() {
    local py="$1"
    "$py" -c "import textual" >/dev/null 2>&1
}

if [[ -x "${_venv}/bin/python3" ]] && _python_has_textual "${_venv}/bin/python3"; then
    PYTHON="${_venv}/bin/python3"
else
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
