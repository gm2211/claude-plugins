# Claude Code — Dockerized Sandbox

## Overview
Run Claude Code in a locked-down Docker container. Claude runs with `--dangerously-skip-permissions` because the **container itself IS the sandbox** — Docker enforces isolation while Claude operates freely inside.

Includes full dev environment: Zellij terminal multiplexer, Neovim with AstroNvim, Zsh with Starship prompt, and the claude-multiagent plugin pre-installed.

## Quick Start

```bash
# Interactive wizard — handles everything
./plugins/claude-multiagent/docker/launch.sh

# Specify a repo directly
./plugins/claude-multiagent/docker/launch.sh owner/repo

# Non-interactive (for CI/automation)
./plugins/claude-multiagent/docker/launch.sh --prompt "fix the failing tests" owner/repo
```

## Prerequisites

- **Docker Desktop** (or Docker Engine) — [Get Docker](https://docker.com/get-started)
- **GitHub CLI** (`gh`) — `brew install gh` on macOS, or [Linux install guide](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)
- **Anthropic API key** — from [console.anthropic.com](https://console.anthropic.com)

## How Authentication Works

### Interactive (recommended)

The launch script uses GitHub's **device flow** — no manual token creation needed:

1. Run `./plugins/claude-multiagent/docker/launch.sh`
2. If not authenticated, a browser opens to `github.com/login/device`
3. Enter the one-time code shown in your terminal
4. Authorize the GitHub CLI
5. Done — the script generates a token automatically

### CI / Automation

For headless environments, create a fine-grained Personal Access Token:

1. Go to [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new)
2. Set **"Only select repositories"** → pick your target repo
3. Grant permissions: **Contents** (R/W), **Pull Requests** (R/W), **Metadata** (Read)
4. Pass as `GH_TOKEN` environment variable

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | Yes | — | Anthropic API key for Claude |
| `GH_TOKEN` | Yes | — | GitHub token (auto by launch.sh, or manual PAT) |
| `REPO` | Yes | — | Target repository (`owner/name`) |
| `REPO_BRANCH` | No | default branch | Branch to checkout after cloning |
| `CLAUDE_MODEL` | No | — | Model override (haiku/sonnet/opus) |
| `CLAUDE_PROMPT` | No | — | Non-interactive mode prompt |
| `GIT_USER_NAME` | No | Claude Agent | Git commit author name |
| `GIT_USER_EMAIL` | No | claude@agent.local | Git commit author email |
| `MAX_BUDGET_USD` | No | — | Maximum API spend limit in USD |

## Usage Examples

### Interactive Development
```bash
./plugins/claude-multiagent/docker/launch.sh owner/repo
# Zellij opens inside the container
# Type 'cc' to start Claude Code
```

### Non-Interactive Task
```bash
./plugins/claude-multiagent/docker/launch.sh --prompt "review the codebase and create a summary" owner/repo
```

### Docker Compose
```bash
export ANTHROPIC_API_KEY=sk-ant-...
export GH_TOKEN=$(gh auth token)
export REPO=owner/repo
docker compose -f plugins/claude-multiagent/docker/docker-compose.yml up
```

### Custom Branch and Model
```bash
./plugins/claude-multiagent/docker/launch.sh --branch feature-x --model opus owner/repo
```

### Force Rebuild
```bash
./plugins/claude-multiagent/docker/launch.sh --rebuild owner/repo
```

### Claude Code Skill
From within Claude Code:
```
/claude-in-docker owner/repo
```

## What's Inside the Container

| Tool | Version | Purpose |
|---|---|---|
| Claude Code | latest | AI coding assistant |
| claude-multiagent | latest | Multi-agent coordinator plugin |
| Zellij | latest | Terminal multiplexer (Catppuccin Mocha theme) |
| Neovim | stable | Editor (AstroNvim distribution) |
| Zsh + Starship | latest | Shell + prompt |
| GitHub CLI | latest | GitHub operations |
| Beads (`bd`) | 0.56.1 | Git-backed issue tracker |
| Node.js | 22 LTS | JavaScript runtime |
| Python | 3.11+ | Python runtime |

## Security Model

- **Container = sandbox**: Docker enforces filesystem and process isolation
- **Unrestricted network**: Full internet egress (needed for API calls, git, npm, etc.)
- **`--dangerously-skip-permissions`**: Safe because the container IS the sandbox
- **Scoped GitHub access**: Token from device flow inherits your permissions; fine-grained PATs limit to one repo
- **No baked secrets**: All credentials passed via environment variables at runtime
- **Ephemeral**: Fresh git clone each run, no state persists between containers
- **Resource limits**: 4GB RAM, 2 CPUs (configurable in docker-compose.yml or launch.sh)

## Building Manually

```bash
# From repo root
docker build -t claude-multiagent -f plugins/claude-multiagent/docker/Dockerfile .

# Multi-arch build
docker buildx build --platform linux/amd64,linux/arm64 -t claude-multiagent -f plugins/claude-multiagent/docker/Dockerfile .
```

## Troubleshooting

### Docker not running
```
Error: Docker daemon is not running
```
Start Docker Desktop and try again.

### GitHub auth fails
```bash
# Re-authenticate
gh auth login --web
```

### Get a shell without Claude
```bash
docker run --rm -it --entrypoint /bin/zsh \
  -e GH_TOKEN=$(gh auth token) \
  -e ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY \
  -e REPO=owner/repo \
  claude-multiagent
```

### Check container logs
```bash
docker logs <container-id>
```

### Image too large
The image includes a full dev environment. For a minimal image (no Zellij/nvim/starship), modify the Dockerfile to skip those layers.
