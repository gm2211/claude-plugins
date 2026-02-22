# My Collection Of Claude Plugins

This repo / marketplaces will contain plugins I develop as I'm trying to hone my dev flow. 
| :warning: WARNING           |
|:----------------------------|
| Maybe they work for you too, maybe they won't. |
| Maybe they'll make cladue hallucinate and wipe your computer 🤷 |
| Install at your own risk. |

# 1. claude-multiagent

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that turns Claude into an async coordinator -- it delegates all implementation to background sub-agents working in git worktrees while staying responsive to you.

> [!IMPORTANT]  
> You have to remind Claude, every now and then, that it is a coordinator (I just say "yo, you're supposed to be the coordinator"). This is especially true in a new session, no matter how strongly worded the prompt in the hook for this plugin is.

## Install

```
/plugin marketplace add gm2211/claude-plugins
/plugin install claude-multiagent@gm2211-plugins
```

> **Note:** The marketplace name is `gm2211-plugins` (the repo can host multiple plugins). The plugin name is `claude-multiagent`.

<img width="1697" height="927" alt="image" src="https://github.com/user-attachments/assets/7d9cf63b-a41b-4d90-82f2-c73a2fc173dc" />

## What You Get

- **Async dispatch** -- describe work, Claude files a ticket and spawns a sub-agent, you keep talking to it (basically team mode, but without having to figure out team composition)
- **Git worktree isolation** -- each agent works in `.worktrees/<branch>`, no interference
- **Tickets and active agents dashboards** -- live ticket list + agent status panes alongside your Claude session
- **Auto-cleanup** -- merge, remove worktree, close ticket, all in one step

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Zellij](https://zellij.dev/) terminal multiplexer
- [bd (beads)](https://github.com/gm2211/beads) issue tracker
- Git

## Required Permissions

On first use in a repo, the plugin detects missing permissions and offers to configure `.claude/settings.local.json` automatically. Just approve the prompt and restart the session.

<details>
<summary>Manual setup (or reference)</summary>

Add to your repo's `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": ["Read", "Edit", "Write", "Bash(bd:*)", "Bash(git:*)"]
  },
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

**Why this works:** `autoAllowBashIfSandboxed` auto-allows all bash commands within Claude's sandbox (filesystem restricted to repo dir, network restricted). `Read`/`Edit`/`Write` are explicitly allowed since they're not bash commands. `bd` and `git` are explicitly allowed for clarity.

Add your own project-specific permissions (build tools, test runners, etc.) to the `allow` array.

</details>

## License

MIT
