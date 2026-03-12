# Claude Code — Docker Sandbox Template

## Overview

Custom [Docker Sandbox template](https://docs.docker.com/ai/sandboxes/templates/) that extends `docker/sandbox-templates:claude-code` with a full dev environment: Zellij, Neovim (AstroNvim), Zsh + Starship, and custom shell configs.

Docker Sandbox handles the lifecycle (workspace mounting, auth, Claude Code launch). This template just adds the tools and configs.

## Quick Start

```bash
# Build the template (from repo root)
docker build -t gm-claude-dev -f plugins/claude-multiagent/docker/Dockerfile .

# Launch (mounts current directory as workspace)
docker sandbox run -t gm-claude-dev claude .

# Or use the shell alias
clauded .
```

## Prerequisites

- **Docker Desktop** with Sandbox support
- **`ANTHROPIC_API_KEY`** set in your shell config (`.zshrc` / `.bashrc`) — Docker Sandbox uses a daemon that doesn't inherit env vars from the current session

## What's Baked In

| Tool | Purpose |
|---|---|
| Zellij | Terminal multiplexer (Catppuccin Mocha, zjstatus bar) |
| Neovim | Editor (AstroNvim distribution) |
| Zsh + Starship | Shell + prompt |
| GitHub CLI | GitHub operations |
| Beads (`bd`) | Git-backed issue tracker |
| Dolt | Versioned database (beads backend) |
| colorls | Colorized `ls` with icons |
| pbcopy (OSC 52) | Clipboard passthrough to host terminal |

Plus all configs from `shell-configs/` (zellij layouts, nvim plugins, zsh functions, claude status line).

## Building

```bash
# From repo root
docker build -t gm-claude-dev -f plugins/claude-multiagent/docker/Dockerfile .

# Multi-arch
docker buildx build --platform linux/amd64,linux/arm64 -t gm-claude-dev -f plugins/claude-multiagent/docker/Dockerfile .
```

## Usage

```bash
# Current directory
docker sandbox run -t gm-claude-dev claude .

# Specific project
docker sandbox run -t gm-claude-dev claude ~/projects/my-app

# Multiple workspaces (docs read-only)
docker sandbox run -t gm-claude-dev claude ~/projects/my-app ~/docs:ro

# Named sandbox (reconnect later with same name)
docker sandbox run --name my-project -t gm-claude-dev claude .

# Pass args to Claude Code
docker sandbox run -t gm-claude-dev claude . -- --continue
```

## Shell Alias

The `clauded` function in `functions.zsh`:

```zsh
clauded() {
  docker sandbox run -t gm-claude-dev claude "$@"
}
```

## Pushing to a Registry

```bash
docker tag gm-claude-dev myorg/gm-claude-dev:v1
docker push myorg/gm-claude-dev:v1

# Team members use:
docker sandbox run -t myorg/gm-claude-dev:v1 claude .
```
