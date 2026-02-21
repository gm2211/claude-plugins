# Agent Progress via Beads Comments

**Date:** 2026-02-21
**Status:** Accepted

## Context

Agents currently report progress by writing TSV status files to `.agent-status.d/`, displayed by a dedicated curses TUI (`watch-agents.py`) in a separate Zellij pane. Meanwhile, the beads-tui already shows a "Latest Update" column with the last comment per ticket, refreshing every 5 seconds.

Two systems showing agent progress is redundant. The beads-tui is richer (shows all ticket metadata) and already handles live reload.

## Decision

Replace the `.agent-status.d/` file mechanism with `bd comment` on assigned tickets. Remove the agents pane and status monitor agent.

**Before:** Agents -> `.agent-status.d/` files -> `watch-agents.py`
**After:** Agents -> `bd comment <ticket-id> "..."` -> beads-tui "Latest Update" column

### Comment Format (structured)

```
[2/5] Writing tests
Done: Implemented auth middleware
Doing: Unit tests for login flow
Blockers: none
ETA: ~3 min
Files: src/auth.ts, src/auth.test.ts
```

### Removed

- `.agent-status.d/` directory and all references
- `watch-agents.py` (curses TUI)
- Status Monitor Agent (Haiku agent for stale detection / ralph-loop)
- Agents pane from Zellij dashboard

### Dashboard Layout (after)

```
+----------------+----------------+
|                |  beads-tui     |
|   Claude       +----------------+
|                |  watch-deploys |
+----------------+----------------+
```

## Consequences

- Single source of truth for ticket status and agent progress
- One fewer pane, simpler dashboard
- Comments persist in git history (status files were ephemeral)
- No automatic stale-agent detection; coordinator monitors via beads-tui
- `bd comment` adds ~0.44s per call; at 60s intervals this is negligible
