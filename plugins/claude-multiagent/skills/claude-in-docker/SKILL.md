---
name: claude-in-docker
description: Launch a sandboxed Claude Code container for a GitHub repo, or attach to an existing one
user_invocable: true
---

# Claude in Docker

Launch a Dockerized Claude Code instance for a specific GitHub repo, or attach to a running container.

**Important:** This skill runs inside Claude Code and must NOT attempt to be interactive. Claude gathers all required information from the user first, then runs `launch.sh` non-interactively and reports back the container name.

## Steps

### 1. Parse the user's intent from the invocation arguments

Check what arguments were passed when the skill was invoked:

- If args contain `--attach` or the user said "attach", "reconnect", or "existing container" → set MODE=attach
- If args contain a repo in `owner/repo` format → set REPO=<that value>, MODE=launch
- If args contain `--help` or `-h` → set MODE=help
- Otherwise → set MODE=launch

Also extract any optional flags the user requested:
- `--prompt "..."` — non-interactive mode with a specific task
- `--branch <branch>` — checkout a specific branch
- `--model <model>` — override the Claude model
- `--budget <usd>` — set max API spend
- `--rebuild` — force rebuild the Docker image
- `--no-push` — autonomous mode (commits stay local, no git push)
- `--persistent` — reuse a per-repo Docker volume instead of fresh clone

### 2. Ask the user for missing required information (before running anything)

**Do not run launch.sh until you have all required information.**

**For MODE=launch:** If REPO is not set (no `owner/repo` in the args), ask the user:

> "Which GitHub repo would you like to launch Claude in? Please specify as `owner/repo` (e.g. `acme/my-service`)."

Wait for the user's answer and set REPO to their response before proceeding.

**For MODE=attach:** List running containers first (see Step 4), then ask the user which container to attach to.

**For MODE=help:** Skip to Step 4 directly.

### 3. Locate the launch script

Run the following to find the launch script path:

```bash
LAUNCH_SH="${CLAUDE_PLUGIN_ROOT}/docker/launch.sh"
if [ ! -f "$LAUNCH_SH" ]; then
  echo "ERROR: launch.sh not found at $LAUNCH_SH"
  echo "CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT}"
  ls "${CLAUDE_PLUGIN_ROOT}/../../docker/" 2>/dev/null || echo "docker/ directory not found"
fi
```

If the script is not found at that path, report the error with the actual value of `$CLAUDE_PLUGIN_ROOT` and the directory listing so the user can diagnose the installation. Stop here.

### 4. Check prerequisites before running

Run:

```bash
command -v docker &>/dev/null && echo "docker: ok" || echo "docker: NOT FOUND"
docker info &>/dev/null && echo "docker daemon: running" || echo "docker daemon: NOT RUNNING"
command -v gh &>/dev/null && echo "gh: ok" || echo "gh: NOT FOUND (GH_TOKEN mode only)"
test -n "${GH_TOKEN:-}" && echo "GH_TOKEN: set" || echo "GH_TOKEN: NOT SET"
```

If `docker` is not installed, tell the user: "Docker is required. Install it from https://docker.com/get-started"

If the Docker daemon is not running, tell the user: "Docker daemon is not running. Start Docker Desktop and try again."

If `gh` is not installed and `GH_TOKEN` is not set, tell the user:
"Either install GitHub CLI (`brew install gh`) or set `GH_TOKEN`."

Stop here if any prerequisite is missing.

### 5. Execute the launch script (non-interactively)

Construct the command based on MODE and any flags extracted in Step 1, then run it via Bash. **Always capture stdout and stderr.**

**Help mode:**
```bash
bash "${CLAUDE_PLUGIN_ROOT}/docker/launch.sh" --help 2>&1
```

**Attach mode:**

First, list existing containers so the user can choose:
```bash
docker ps -a --filter "ancestor=claude-multiagent" --format 'table {{.Names}}\t{{.Status}}\t{{.ID}}' 2>&1
```

Show that output to the user and ask which container name they want to attach to. Then run:
```bash
# Restart container if needed and show its name
CONTAINER_NAME="<name chosen by user>"
STATE=$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null)
if [ "$STATE" = "exited" ] || [ "$STATE" = "created" ]; then
  docker start "$CONTAINER_NAME"
fi
echo "ATTACHED_CONTAINER=$CONTAINER_NAME"
```

**Launch mode (repo known from Step 2):**

The container name that `launch.sh` will create is deterministic:
```
claude-<owner>-<repo>   (slashes and dots replaced with hyphens)
```

Build the full command with all flags. **Always include `--prompt` to prevent launch.sh from dropping into an interactive shell.** If the user did not supply a prompt, use `--prompt "ready"` as a sentinel so the container starts in non-interactive mode:

```bash
LAUNCH_FLAGS=""
[ -n "$REPO_BRANCH" ]     && LAUNCH_FLAGS="$LAUNCH_FLAGS --branch $REPO_BRANCH"
[ -n "$CLAUDE_MODEL" ]    && LAUNCH_FLAGS="$LAUNCH_FLAGS --model $CLAUDE_MODEL"
[ -n "$MAX_BUDGET_USD" ]  && LAUNCH_FLAGS="$LAUNCH_FLAGS --budget $MAX_BUDGET_USD"
[ "$FORCE_REBUILD" = "true" ] && LAUNCH_FLAGS="$LAUNCH_FLAGS --rebuild"
[ "$NO_PUSH" = "true" ]   && LAUNCH_FLAGS="$LAUNCH_FLAGS --no-push"
[ "$PERSIST_REPO" = "true" ] && LAUNCH_FLAGS="$LAUNCH_FLAGS --persistent"

# Use the user-supplied prompt, or the sentinel "ready" for non-interactive startup
PROMPT_VALUE="${CLAUDE_PROMPT:-ready}"

bash "${CLAUDE_PLUGIN_ROOT}/docker/launch.sh" \
  $LAUNCH_FLAGS \
  --prompt "$PROMPT_VALUE" \
  "$REPO" 2>&1
```

Capture the full output. The launch script prints the container name in multiple places:
- `[INFO]  Container: <container_name>` — in the summary block
- `[INFO]  Container started: <short-id>` — immediately after `docker run`

Extract the container name from the output:
```bash
CONTAINER_NAME=$(echo "$OUTPUT" | grep -oP '(?<=Container: )[^\s]+' | head -1)
```

If `CONTAINER_NAME` is still empty, derive it from the repo name directly:
```bash
CONTAINER_NAME="claude-$(echo "$REPO" | tr '/' '-' | tr '.' '-')"
```

Confirm it is running:
```bash
docker ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}\t{{.Status}}' 2>&1
```

### 6. Report results

**On success (launch mode):**
Report back clearly:

```
Container launched: <container_name>

To attach a shell:
  docker exec -it <container_name> /bin/zsh -l

To view logs:
  docker logs -f <container_name>

To stop:
  docker stop <container_name>
```

**On success (attach mode):**
Report back:

```
Attached to: <container_name>

To open a shell:
  docker exec -it <container_name> /bin/zsh -l

To view logs:
  docker logs -f <container_name>
```

**On error:**
Show the captured stderr/stdout and suggest remediation:
- Check Docker is running: `docker info`
- Check GitHub auth: `gh auth status`
- Rebuild the image: invoke the skill again with `--rebuild`
- View container logs: `docker logs <container_name>`
