#!/usr/bin/env bash
set -euo pipefail

# Show the failing command on error instead of silently exiting
trap 'log_error "Command failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
log_info()    { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_success() { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; }
log_error()   { printf '\033[1;31m[ERR]\033[0m  %s\n' "$*" >&2; }
die()         { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Validate required environment variables
# ---------------------------------------------------------------------------
missing=()
[ -z "${GH_TOKEN:-}" ] && missing+=("GH_TOKEN")
[ -z "${REPO:-}" ]     && missing+=("REPO")

if [ ${#missing[@]} -gt 0 ]; then
    die "Missing required environment variable(s): ${missing[*]}"
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    log_info "No ANTHROPIC_API_KEY set — run 'claude login' inside the container to authenticate"
fi

# ---------------------------------------------------------------------------
# 2. Configure git identity & credentials
# ---------------------------------------------------------------------------
git config --global user.name  "${GIT_USER_NAME:-Claude Agent}"
git config --global user.email "${GIT_USER_EMAIL:-claude@agent.local}"
git config --global init.defaultBranch main

# Use GH_TOKEN directly for git HTTPS auth (no gh auth login needed)
git config --global credential.helper '!f() { echo "username=x-access-token"; echo "password=${GH_TOKEN}"; }; f'

log_info "Git identity: $(git config --global user.name) <$(git config --global user.email)>"
log_success "Git credentials configured via GH_TOKEN"

# ---------------------------------------------------------------------------
# 3. Clone repository
# ---------------------------------------------------------------------------
log_info "Cloning $REPO..."
git clone --depth=50 "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" /home/claude/repo
cd /home/claude/repo

if [ -n "${REPO_BRANCH:-}" ]; then
    git checkout "$REPO_BRANCH"
fi

CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
log_success "Cloned $REPO (branch: $CURRENT_BRANCH)"

# ---------------------------------------------------------------------------
# 4. Initialize Beads
# ---------------------------------------------------------------------------
if command -v bd &>/dev/null; then
    bd init 2>/dev/null || true
    git config beads.role maintainer 2>/dev/null || true
    log_info "Beads initialised (best-effort)"
fi

# ---------------------------------------------------------------------------
# 5. Write Claude project settings
# ---------------------------------------------------------------------------
mkdir -p /home/claude/repo/.claude
cat > /home/claude/repo/.claude/settings.local.json << 'SETTINGS'
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "permissions": {
    "allow": [
      "Read", "Edit", "Write",
      "Bash(git:*)", "Bash(bd:*)", "Bash(gh:*)",
      "Bash(python3:*)", "Bash(node:*)", "Bash(npm:*)",
      "Bash(npx:*)", "Bash(find:*)", "Bash(wc:*)",
      "Bash(echo:*)", "Bash(head:*)", "Bash(tail:*)",
      "Bash(mkdir:*)", "Bash(cp:*)", "Bash(mv:*)",
      "Bash(rm:*)", "Bash(ls:*)", "Bash(cat:*)",
      "Bash(chmod:*)", "Bash(curl:*)", "Bash(wget:*)",
      "Bash(pip:*)", "Bash(pip3:*)",
      "Bash(zellij action:*)",
      "Bash(docker:*)",
      "Bash(make:*)", "Bash(cargo:*)", "Bash(go:*)",
      "WebSearch", "WebFetch(domain:*)"
    ]
  },
  "sandbox": {
    "enabled": false
  }
}
SETTINGS

log_info "Claude project settings written"

# ---------------------------------------------------------------------------
# 6. Write claude-multiagent local config
# ---------------------------------------------------------------------------
cat > /home/claude/repo/.claude/claude-multiagent.local.md << 'EOF'
deploy_pane: disabled
EOF

# ---------------------------------------------------------------------------
# 7. Write no-push autonomous mode instructions (when NO_PUSH=true)
# ---------------------------------------------------------------------------
if [ "${NO_PUSH:-}" = "true" ]; then
    mkdir -p /home/claude/repo/.claude
    cat >> /home/claude/repo/.claude/CLAUDE.md << 'NOPUSH'

## Autonomous No-Push Mode

This container is running in `--no-push` mode. Git push is disabled.

### Rules for this mode:
1. **NEVER attempt `git push`** — it will be rejected by the pre-push hook
2. **NEVER block waiting for review or user approval** — keep working
3. **After merging task → epic:** immediately check `bd ready` and start the next task
4. **After merging epic → main:** skip `git push`, check for more epics/tasks, keep going
5. **Keep working through ALL open beads** until no unblocked work remains
6. **Do not ask "should I push?"** or "ready for review?" — the answer is always "keep going"
7. **When all beads are closed** and no work remains, output a final summary:
   ```
   All work committed locally.
   Review: git log --oneline -20
   Push when ready: git push
   ```

### Session Close Protocol Override
The normal "git push" step in the session close protocol is SKIPPED in no-push mode.
Instead: commit all changes, verify all beads are closed, output the summary above.
NOPUSH

    log_info "No-push autonomous mode instructions written to CLAUDE.md"
fi

# ---------------------------------------------------------------------------
# 8. Build Claude command arguments
# ---------------------------------------------------------------------------
CLAUDE_ARGS=("--dangerously-skip-permissions")

if [ -n "${CLAUDE_MODEL:-}" ]; then
    CLAUDE_ARGS+=("--model" "$CLAUDE_MODEL")
fi

if [ -n "${MAX_BUDGET_USD:-}" ]; then
    CLAUDE_ARGS+=("--max-cost-dollars" "$MAX_BUDGET_USD")
fi

# Create the `cc` wrapper so every shell session gets the right flags
mkdir -p /home/claude/.local/bin
cat > /home/claude/.local/bin/cc << WRAPPER
#!/usr/bin/env bash
exec claude ${CLAUDE_ARGS[*]} "\$@"
WRAPPER
chmod +x /home/claude/.local/bin/cc

# ---------------------------------------------------------------------------
# Non-interactive mode (CLAUDE_PROMPT is set) — run and exit
# ---------------------------------------------------------------------------
if [ -n "${CLAUDE_PROMPT:-}" ]; then
    log_info "Running non-interactive: $CLAUDE_PROMPT"
    cd /home/claude/repo
    exec claude "${CLAUDE_ARGS[@]}" --print "$CLAUDE_PROMPT"
fi

# ---------------------------------------------------------------------------
# Daemon mode — container stays alive, users attach via docker exec
# ---------------------------------------------------------------------------
log_success "Container ready. Repo: $REPO (branch: $CURRENT_BRANCH)"
log_info "Container will keep running. Attach with: docker exec -it <container> /bin/zsh -l"

cd /home/claude/repo

# Keep container alive — PID 1 sleeps forever.
# Users connect via `docker exec -it <name> /bin/zsh -l`
# and run `cc` to start Claude Code.
exec sleep infinity
