---
name: dashboard
description: Set up zellij dashboard panes showing open tickets and agent status alongside your Claude session
---

# Zellij Dashboard Setup

On session start, if inside Zellij and in a git repo, add dashboard panes to the **current tab**.

## Prerequisites Check

1. **Zellij:** Check `$ZELLIJ` env var. If not set, tell the user: "For the best experience, run Claude inside Zellij: `zellij` then `claude`"
2. **bd:** Check for `.beads/` directory. If missing, tell the user: "Run `bd init` to enable ticket tracking"

## Setup Commands

Run these three commands in order:

```bash
# Beads pane (right side)
zellij action new-pane --direction right -- bash -c "cd $(pwd) && ${CLAUDE_PLUGIN_ROOT}/scripts/watch-beads.sh"

# Agent status pane (below beads)
zellij action new-pane --direction down -- bash -c "cd $(pwd) && ${CLAUDE_PLUGIN_ROOT}/scripts/watch-agents.sh"

# Return focus to Claude
zellij action move-focus left
```

If `${CLAUDE_PLUGIN_ROOT}` is not available, fall back to `$HOME/.claude/scripts/` as the script location.

## Safety Rules

**ONLY** use `new-pane` and `move-focus` Zellij actions. **NEVER** use:
- `close-pane` -- kills your own pane
- `close-tab` -- kills your own tab
- `go-to-tab` -- navigates away from your session
