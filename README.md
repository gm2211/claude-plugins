# claude-flows

A workflow that turns [Claude Code](https://docs.anthropic.com/en/docs/claude-code) into an async coordinator -- it delegates all implementation to background sub-agents working in git worktrees while staying responsive to you.

## Install

```bash
git clone https://github.com/gm2211/claude-flows.git
cd claude-flows && ./install.sh
```

Then:
1. Copy `CLAUDE.md` to `~/.claude/CLAUDE.md` (or merge it into your existing one)
2. Add the permissions from the HTML comment at the bottom of `CLAUDE.md` to `~/.claude/settings.json`

## What You Get

- **Async dispatch** -- describe work, Claude files a ticket and spawns a sub-agent, you keep talking
- **Git worktree isolation** -- each agent works in `.worktrees/<branch>`, no interference
- **Zellij dashboard** -- live ticket list + agent status panes alongside your Claude session
- **Auto-cleanup** -- merge, remove worktree, close ticket, all in one step

## How It Works

You talk to Claude. For every feature or bug, it creates a [bd](https://github.com/gm2211/beads) ticket and dispatches a sub-agent into its own git worktree. Agents send heartbeat updates; a Zellij dashboard shows tickets and agent progress in real time. When an agent finishes, Claude reviews the diff, merges to main, and cleans up.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Zellij](https://zellij.dev/) terminal multiplexer
- [bd (beads)](https://github.com/gm2211/beads) issue tracker
- Git

## License

MIT
