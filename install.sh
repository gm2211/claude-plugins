#!/bin/bash
# claude-flows installer
# Copies watcher scripts to ~/.claude/scripts/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "Installing claude-flows..."
echo ""

# Copy scripts
mkdir -p "$CLAUDE_DIR/scripts"
cp "$SCRIPT_DIR/scripts/watch-beads.sh" "$CLAUDE_DIR/scripts/watch-beads.sh"
cp "$SCRIPT_DIR/scripts/watch-agents.sh" "$CLAUDE_DIR/scripts/watch-agents.sh"
chmod +x "$CLAUDE_DIR/scripts/watch-beads.sh"
chmod +x "$CLAUDE_DIR/scripts/watch-agents.sh"
echo "  Copied scripts to $CLAUDE_DIR/scripts/"

echo ""
echo "Done! Next steps:"
echo ""
echo "  1. Copy CLAUDE.md to ~/.claude/CLAUDE.md (or merge into your existing one)"
echo "  2. Add the permissions from the HTML comment at the bottom of CLAUDE.md"
echo "     to ~/.claude/settings.json"
echo "  3. Install prerequisites if needed:"
echo "     - bd (beads): https://github.com/gm2211/beads"
echo "     - Zellij: https://zellij.dev/documentation/installation"
echo ""
echo "  Then: cd your-project && bd init && zellij && claude"
