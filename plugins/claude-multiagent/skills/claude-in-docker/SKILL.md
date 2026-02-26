---
name: claude-in-docker
description: Launch or attach to a sandboxed Claude Code container for a specific repo
user_invocable: true
---

# Claude in Docker

Launch a Dockerized Claude Code instance with the claude-multiagent plugin, or attach to an existing one.

## Usage

- `/claude-in-docker` — interactive wizard (pick repo, configure options)
- `/claude-in-docker owner/repo` — launch directly for a specific repo
- `/claude-in-docker --attach` — list running containers and attach to one

## Instructions

When this skill is invoked:

1. **Determine what the user wants:**
   - If `--attach` or user mentions "attach"/"reconnect"/"existing" → run `launch.sh --attach`
   - If a repo argument was provided → pass it to launch.sh
   - Otherwise → run launch.sh interactively (it will prompt for repo selection)

2. **Locate and execute the launch script:**
   The script lives relative to the plugin installation. Find it by checking these paths in order:
   - `${CLAUDE_PLUGIN_ROOT}/docker/launch.sh` (when running from plugin cache)
   - The repo root's `plugins/claude-multiagent/docker/launch.sh` (when running from the source repo)

   Run via Bash tool. The script is interactive — it handles GitHub auth, repo selection, image building, and container launch/attach.

3. **Pass through any flags** the user requests:
   - `--prompt "..."`: Non-interactive mode
   - `--branch <branch>`: Checkout specific branch
   - `--model <model>`: Claude model override
   - `--budget <usd>`: API spend limit
   - `--rebuild`: Force rebuild Docker image
   - `--attach`: List and attach to existing containers

## Prerequisites

The host machine needs:
- Docker Desktop (or Docker Engine) running
- GitHub CLI (`gh`) — `brew install gh`

## What Happens

**New container:** Auth with GitHub → pick repo → build image → clone repo inside container → launch Zellij with full dev environment → type `cc` to start Claude Code.

**Attach to existing:** Lists running claude-multiagent containers showing repo and uptime → pick one → attach with interactive shell.
