# claude-multiagent

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that turns Claude into an async coordinator -- it delegates all implementation to background sub-agents working in git worktrees while staying responsive to you.

## Install

```bash
claude plugin add -- /path/to/claude-multiagent
# or from GitHub:
claude plugin add -- https://github.com/gm2211/claude-multiagent
```

## What You Get

- **Async dispatch** -- describe work, Claude files a ticket and spawns a sub-agent, you keep talking
- **Git worktree isolation** -- each agent works in `.worktrees/<branch>`, no interference
- **Zellij dashboard** -- live ticket list + agent status panes alongside your Claude session
- **Auto-cleanup** -- merge, remove worktree, close ticket, all in one step

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Zellij](https://zellij.dev/) terminal multiplexer
- [bd (beads)](https://github.com/gm2211/beads) issue tracker
- Git

## Required Permissions

Add to `~/.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "permissions": {
    "allow": [
      "Bash(git add:*)", "Bash(git commit:*)", "Bash(git push:*)",
      "Bash(git pull:*)", "Bash(git checkout:*)", "Bash(git merge:*)",
      "Bash(git branch:*)", "Bash(git stash:*)", "Bash(git diff:*)",
      "Bash(git log:*)", "Bash(git worktree:*)", "Bash(git cherry-pick:*)",
      "Bash(git status:*)", "Bash(chmod:*)", "Bash(xargs:*)",
      "Bash(mkdir:*)", "Bash(cat:*)", "Bash(sleep:*)", "Bash(tail:*)",
      "Bash(printf:*)", "Bash(cd:*)", "Bash(bd:*)", "Bash(zellij:*)",
      "Bash(npm ci:*)", "Bash(npm install:*)", "Bash(npm run:*)",
      "Bash(npx tsc:*)", "Bash(npx vitest:*)", "Bash(npx prisma:*)",
      "Bash(npx tsx:*)", "Bash(node:*)", "WebSearch"
    ]
  }
}
```

## License

MIT
