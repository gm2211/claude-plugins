# claude-multiagent

A Claude Code plugin that adds multi-agent coordination, a Zellij dashboard with
deploy/CI monitoring and bead (ticket) tracking, and Docker-based agent isolation.

## Directory layout

```
plugins/claude-multiagent/
├── hooks/                        # Claude Code lifecycle hooks
│   ├── hooks.json                #   hook registration (SessionStart, etc.)
│   ├── session-start.sh          #   opens dashboard panes, bootstraps venvs
│   └── claude-activity-hook.sh   #   activity heartbeat for idle detection
│
├── scripts/                      # Runtime scripts
│   ├── open-dashboard.sh         #   create Zellij dashboard panes
│   ├── close-dashboard.sh        #   tear down dashboard panes on session end
│   ├── bd-create-with-seq-id.sh  #   wrapper: `bd create` with sequential IDs
│   ├── prepare-agent.sh          #   bootstrap a sub-agent environment
│   ├── worktree-setup.sh         #   git worktree helpers for agent isolation
│   ├── beads-tui/                #   git submodule — bead tracker TUI
│   └── watch-dashboard/          #   deploy/CI monitoring TUI (Textual)
│       ├── run.sh                #     entry point
│       ├── providers/            #     pluggable deploy-data providers
│       │   ├── README.md         #       provider contract docs
│       │   ├── github-actions    #       GitHub Actions provider
│       │   └── renderdotcom.py   #       Render.com provider
│       └── watch_dashboard/      #     Python package
│
├── skills/                       # Slash-command skills
│   ├── multiagent-coordinator/   #   /multiagent — orchestrate sub-agents
│   ├── panes/                    #   /agents-dashboard — manage dashboard panes
│   └── claude-in-docker/         #   /claude-in-docker — run agents in containers
│
└── docs/                         # Additional documentation
```

## Key concepts

- **Beads** — lightweight tickets (bugs, tasks, features) stored in a local
  SQLite DB (`.beads/beads.db`).  Managed by `bd` CLI and the `beads-tui` TUI.
- **Providers** — executable scripts that fetch deploy/CI data in a standard
  JSON-lines format.  See `scripts/watch-dashboard/providers/README.md`.
- **Dashboard** — a set of Zellij panes (beads tracker + deploy/CI watcher)
  that open automatically on session start and close on session end.
- **Sequential IDs** — `bd-create-with-seq-id.sh` assigns human-friendly
  `<prefix>-<N>` IDs (e.g. `plug-42`) instead of random hashes.

## Beads DB Scope

Dashboard beads panes use a configurable database scope via
`CLAUDE_MULTIAGENT_BEADS_DB_MODE`:

- `worktree` (default): isolated DB per worktree at
  `<worktree>/.beads/dolt` (legacy `.beads-worktree/dolt` still supported)
- `shared` (or `repo`): shared DB at `<repo>/.beads/dolt`

Optional explicit override:
- `CLAUDE_MULTIAGENT_BEADS_DB_PATH=/absolute/path/to/dolt`
