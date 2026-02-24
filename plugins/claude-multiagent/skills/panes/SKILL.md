---
name: panes
description: Reopen accidentally closed dashboard panes
---

# Panes

Reopen missing dashboard panes (beads-tui ticket tracker and watch-dashboard).

## Steps

### 1. Check Zellij is running

If `$ZELLIJ` is not set, tell the user: "Not inside a Zellij session — dashboard panes require Zellij." Stop here.

### 2. Detect which panes are present

Run:
```bash
zellij action dump-layout
```

Check the output for panes named `dashboard-beads-*` and `dashboard-watch-*`:
- If a line contains `name="dashboard-beads` → beads pane is present
- If a line contains `name="dashboard-watch` → watch pane is present

### 3. Check which panes are disabled

Read (if they exist):
- `.claude/claude-multiagent.local.md` (project-level)
- `~/.claude/claude-multiagent.local.md` (home-level)

Disabled conditions:
- `beads_pane: disabled` in either file → beads pane is disabled
- `dashboard_pane: disabled` or `deploy_pane: disabled` in either file → watch pane is disabled

### 4. If all expected panes are already present

Tell the user: "All dashboard panes are already running." Stop here.

### 5. For missing panes that are NOT disabled

Run the open-dashboard script — it handles detection and only creates missing panes:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/open-dashboard.sh"
```

### 6. For missing panes that ARE disabled

For each missing disabled pane, use `AskUserQuestion` to ask:

- beads pane disabled and missing: "The beads-tui (ticket tracker) pane is disabled. Re-enable it and reopen the pane?"
- watch pane disabled and missing: "The watch-dashboard (deploys/actions) pane is disabled. Re-enable it and reopen the pane?"

If the user says yes:
1. Remove the `disabled` line from `.claude/claude-multiagent.local.md` (the project-level config). If both config files contain the line, remove from both. If neither exists, skip this step.
2. Run `open-dashboard.sh` to create the pane:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/open-dashboard.sh"
   ```

If the user says no, leave the pane disabled and tell them how to re-enable it manually: edit `.claude/claude-multiagent.local.md` and remove the `disabled` line.
