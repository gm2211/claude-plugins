---
name: claude-in-docker
description: Launch a sandboxed Claude Code container for a GitHub repo, or attach to an existing one
user_invocable: true
---

# Claude in Docker

Launch a Dockerized Claude Code instance for a specific GitHub repo, or attach to a running container.

## Steps

### 1. Parse the user's intent from the invocation arguments

Check what arguments were passed when the skill was invoked:

- If args contain `--attach` or the user said "attach", "reconnect", or "existing container" → set MODE=attach
- If args contain a repo in `owner/repo` format → set REPO=<that value>, MODE=launch
- If args contain `--help` or `-h` → set MODE=help
- Otherwise → set MODE=launch (the script will interactively prompt for repo selection)

Also extract any optional flags the user requested:
- `--prompt "..."` — non-interactive mode with a specific task
- `--branch <branch>` — checkout a specific branch
- `--model <model>` — override the Claude model
- `--budget <usd>` — set max API spend
- `--rebuild` — force rebuild the Docker image
- `--no-push` — autonomous mode (commits stay local, no git push)

### 2. Locate the launch script

Run the following to find the launch script path:

```bash
LAUNCH_SH="${CLAUDE_PLUGIN_ROOT}/../../docker/launch.sh"
if [ ! -f "$LAUNCH_SH" ]; then
  echo "ERROR: launch.sh not found at $LAUNCH_SH"
  echo "CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT}"
  ls "${CLAUDE_PLUGIN_ROOT}/../../docker/" 2>/dev/null || echo "docker/ directory not found"
fi
```

If the script is not found at that path, report the error with the actual value of `$CLAUDE_PLUGIN_ROOT` and the directory listing so the user can diagnose the installation.

### 3. Check prerequisites before running

Run:

```bash
command -v docker &>/dev/null && echo "docker: ok" || echo "docker: NOT FOUND"
docker info &>/dev/null && echo "docker daemon: running" || echo "docker daemon: NOT RUNNING"
command -v gh &>/dev/null && echo "gh: ok" || echo "gh: NOT FOUND"
```

If `docker` is not installed, tell the user: "Docker is required. Install it from https://docker.com/get-started"

If the Docker daemon is not running, tell the user: "Docker daemon is not running. Start Docker Desktop and try again."

If `gh` is not installed, tell the user: "GitHub CLI (gh) is required. Install with: brew install gh"

Stop here if any prerequisite is missing.

### 4. Execute the launch script

Construct the command based on MODE and any flags extracted in Step 1, then run it via Bash:

**Help mode:**
```bash
bash "${CLAUDE_PLUGIN_ROOT}/../../docker/launch.sh" --help
```

**Attach mode:**
```bash
bash "${CLAUDE_PLUGIN_ROOT}/../../docker/launch.sh" --attach
```

**Launch mode (with specific repo):**
```bash
bash "${CLAUDE_PLUGIN_ROOT}/../../docker/launch.sh" [FLAGS] owner/repo
```

**Launch mode (interactive — no repo specified):**
```bash
bash "${CLAUDE_PLUGIN_ROOT}/../../docker/launch.sh" [FLAGS]
```

Where `[FLAGS]` is built from the optional flags extracted in Step 1, for example:
- `--rebuild` if the user requested a rebuild
- `--branch main` if a branch was specified
- `--model claude-opus-4-5` if a model was specified
- `--budget 5.00` if a budget was specified
- `--prompt "fix all failing tests"` if a prompt was specified
- `--no-push` if autonomous no-push mode was requested

### 5. Report results

- If the script exits successfully, tell the user the container was launched or attached.
- If the script exits with an error, show the error output and suggest remediation (check Docker is running, check GitHub auth with `gh auth status`, etc.).
- The launch script is interactive — it will prompt the user for repo selection and GitHub auth if needed. Claude should run it and let it interact with the terminal directly.
