# =============================================================================
# Custom Docker Sandbox Template — extends the official Claude Code base
# =============================================================================
# Build:  docker build -t gm-claude-dev -f plugins/claude-multiagent/docker/Dockerfile .
# Use:    docker sandbox run -t gm-claude-dev claude .
# =============================================================================

# =============================================================================
# Stage 1: Builder — prepare claude-multiagent plugin cache
# =============================================================================
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq \
    && rm -rf /var/lib/apt/lists/*

# ADD fetches at build time; Docker invalidates cache when the response changes
ADD https://api.github.com/repos/gm2211/claude-plugins/git/refs/heads/main /tmp/cache-bust-plugins
RUN git clone https://github.com/gm2211/claude-plugins.git /plugin-src \
    && cd /plugin-src \
    && git submodule update --init --recursive

ADD https://api.github.com/repos/anthropics/claude-plugins-official/git/refs/heads/main /tmp/cache-bust-official
RUN git clone https://github.com/anthropics/claude-plugins-official.git /official-src

ADD https://api.github.com/repos/gm2211/specify/git/refs/heads/main /tmp/cache-bust-specify
RUN git clone https://github.com/gm2211/specify.git /specify-src

RUN <<'BUILDER_SCRIPT'
set -eux

# --- gm2211-plugins: claude-multiagent ---
GM_VERSION=$(jq -r '.plugins[] | select(.name=="claude-multiagent") | .version' \
             /plugin-src/.claude-plugin/marketplace.json)
GM_CACHE="/plugin-cache/cache/gm2211-plugins/claude-multiagent/${GM_VERSION}"
mkdir -p "${GM_CACHE}"
cp -a /plugin-src/plugins/claude-multiagent/. "${GM_CACHE}/"

# --- claude-plugins-official: ralph-loop, feature-dev ---
for PLUGIN in ralph-loop feature-dev; do
  # These plugins have version: null in marketplace.json — use "latest"
  PCACHE="/plugin-cache/cache/claude-plugins-official/${PLUGIN}/latest"
  mkdir -p "${PCACHE}"
  cp -a "/official-src/plugins/${PLUGIN}/." "${PCACHE}/"
done

# --- Marketplace manifests (Claude Code validates plugins against these) ---
mkdir -p /plugin-cache/marketplaces/gm2211-plugins/.claude-plugin
cp -a /plugin-src/.claude-plugin/. /plugin-cache/marketplaces/gm2211-plugins/.claude-plugin/

mkdir -p /plugin-cache/marketplaces/claude-plugins-official/.claude-plugin
cp -a /official-src/.claude-plugin/. /plugin-cache/marketplaces/claude-plugins-official/.claude-plugin/

cat > /plugin-cache/installed_plugins.json <<EOJSON
{
  "version": 2,
  "plugins": {
    "claude-multiagent@gm2211-plugins": [
      {
        "scope": "user",
        "installPath": "/home/agent/.claude/plugins/cache/gm2211-plugins/claude-multiagent/${GM_VERSION}",
        "version": "${GM_VERSION}",
        "installedAt": "2026-01-01T00:00:00.000Z",
        "lastUpdated": "2026-01-01T00:00:00.000Z",
        "gitCommitSha": "HEAD"
      }
    ],
    "ralph-loop@claude-plugins-official": [
      {
        "scope": "user",
        "installPath": "/home/agent/.claude/plugins/cache/claude-plugins-official/ralph-loop/latest",
        "version": "latest",
        "installedAt": "2026-01-01T00:00:00.000Z",
        "lastUpdated": "2026-01-01T00:00:00.000Z",
        "gitCommitSha": "HEAD"
      }
    ],
    "feature-dev@claude-plugins-official": [
      {
        "scope": "user",
        "installPath": "/home/agent/.claude/plugins/cache/claude-plugins-official/feature-dev/latest",
        "version": "latest",
        "installedAt": "2026-01-01T00:00:00.000Z",
        "lastUpdated": "2026-01-01T00:00:00.000Z",
        "gitCommitSha": "HEAD"
      }
    ]
  }
}
EOJSON

cat > /plugin-cache/known_marketplaces.json <<EOJSON
{
  "claude-plugins-official": {
    "source": {
      "source": "github",
      "repo": "anthropics/claude-plugins-official"
    },
    "installLocation": "/home/agent/.claude/plugins/marketplaces/claude-plugins-official",
    "lastUpdated": "2026-01-01T00:00:00.000Z"
  },
  "gm2211-plugins": {
    "source": {
      "source": "github",
      "repo": "gm2211/claude-plugins"
    },
    "installLocation": "/home/agent/.claude/plugins/marketplaces/gm2211-plugins",
    "lastUpdated": "2026-01-01T00:00:00.000Z"
  },
  "claude-plugins-official": {
    "source": {
      "source": "github",
      "repo": "anthropics/claude-plugins-official"
    },
    "installLocation": "/home/agent/.claude/plugins/marketplaces/claude-plugins-official",
    "lastUpdated": "2026-01-01T00:00:00.000Z"
  }
}
EOJSON

echo "${GM_VERSION}" > /plugin-cache/.plugin-version
BUILDER_SCRIPT

# =============================================================================
# Stage 2: Custom sandbox template
# =============================================================================
FROM docker/sandbox-templates:claude-code

USER root

ARG TARGETARCH

# ---------------------------------------------------------------------------
# Update Claude Code to latest version
# ---------------------------------------------------------------------------
RUN npm update -g @anthropic-ai/claude-code

# ---------------------------------------------------------------------------
# System packages beyond the base image
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        zsh \
        ruby ruby-dev \
        build-essential \
        unzip \
        uuid-runtime \
        postgresql-client \
        python3-venv \
        openssh-client \
        locales \
        fontconfig \
        jq \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Nerd Fonts — Symbols Only (provides icons for status line, zellij, etc.)
# ---------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p /usr/share/fonts/nerd-fonts; \
    curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.tar.xz" \
        | tar xJ -C /usr/share/fonts/nerd-fonts; \
    fc-cache -fv

# ---------------------------------------------------------------------------
# colorls (colorized ls with icons)
# ---------------------------------------------------------------------------
RUN gem install colorls --no-document

# ---------------------------------------------------------------------------
# GitHub CLI (if not already in base)
# ---------------------------------------------------------------------------
RUN command -v gh >/dev/null 2>&1 || { \
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
        && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | tee /etc/apt/sources.list.d/github-cli.list \
        && apt-get update && apt-get install -y gh \
        && rm -rf /var/lib/apt/lists/*; \
    }

# ---------------------------------------------------------------------------
# DigitalOcean CLI (doctl)
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) DOCTL_ARCH="amd64"  ;; \
        arm64) DOCTL_ARCH="arm64"  ;; \
        *)     echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/digitalocean/doctl/releases/latest/download/doctl-$(curl -fsSL https://api.github.com/repos/digitalocean/doctl/releases/latest | grep -oP '"tag_name":\s*"v\K[^"]+' | head -1)-linux-${DOCTL_ARCH}.tar.gz" \
        | tar xz -C /usr/local/bin; \
    chmod +x /usr/local/bin/doctl

# ---------------------------------------------------------------------------
# Dolt (required by bd/beads issue tracker)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash

# ---------------------------------------------------------------------------
# Beads (bd) binary
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL "https://github.com/steveyegge/beads/releases/download/v0.56.1/beads_0.56.1_linux_${TARGETARCH}.tar.gz" \
        | tar xz -C /tmp; \
    mv /tmp/bd /usr/local/bin/bd; \
    chmod +x /usr/local/bin/bd

# ---------------------------------------------------------------------------
# Zellij (latest release, multi-arch)
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) ZJ_ARCH="x86_64"  ;; \
        arm64) ZJ_ARCH="aarch64" ;; \
        *)     echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/zellij-org/zellij/releases/latest/download/zellij-${ZJ_ARCH}-unknown-linux-musl.tar.gz" \
        | tar xz -C /usr/local/bin; \
    chmod +x /usr/local/bin/zellij

# ---------------------------------------------------------------------------
# Neovim (stable v0.10.x, multi-arch)
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) NVIM_ARCH="x86_64" ;; \
        arm64) NVIM_ARCH="arm64"  ;; \
        *)     echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/neovim/neovim/releases/download/v0.10.4/nvim-linux-${NVIM_ARCH}.tar.gz" \
        | tar xz -C /opt; \
    ln -sf /opt/nvim-linux-${NVIM_ARCH}/bin/nvim /usr/local/bin/nvim

# ---------------------------------------------------------------------------
# Kitty terminfo (for TERM=xterm-kitty from host)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://raw.githubusercontent.com/kovidgoyal/kitty/master/terminfo/kitty.terminfo \
        | tic -x -o /usr/share/terminfo -

# ---------------------------------------------------------------------------
# Specify (sp) — product spec validator
# ---------------------------------------------------------------------------
COPY --from=builder /specify-src /home/agent/projects/specify
RUN ln -sf /home/agent/projects/specify/specify /usr/local/bin/sp

# ---------------------------------------------------------------------------
# Starship prompt
# ---------------------------------------------------------------------------
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- -y

# ---------------------------------------------------------------------------
# Pre-cache DigitalOcean MCP package (avoids download on first use)
# ---------------------------------------------------------------------------
RUN npx -y @digitalocean/mcp --help 2>/dev/null || true

# ---------------------------------------------------------------------------
# Playwright + browsers (for specify captures & e2e testing)
# ---------------------------------------------------------------------------
RUN npx -y playwright install --with-deps chromium

# ---------------------------------------------------------------------------
# pbcopy wrapper (OSC 52 clipboard passthrough)
# ---------------------------------------------------------------------------
RUN printf '#!/bin/sh\ndata=$(base64 | tr -d '"'"'\\n'"'"')\nprintf '"'"'\\033]52;c;%%s\\a'"'"' "$data"\n' \
      > /usr/local/bin/pbcopy \
    && chmod +x /usr/local/bin/pbcopy

# ---------------------------------------------------------------------------
# Set zsh as default shell for agent user
# ---------------------------------------------------------------------------
RUN chsh -s /bin/zsh agent

# ---------------------------------------------------------------------------
# Shell configs — zellij, nvim, zsh, claude status line
# ---------------------------------------------------------------------------
COPY shell-configs/zellij/  /home/agent/.config/zellij/
COPY shell-configs/nvim/    /home/agent/.config/nvim/
COPY shell-configs/zsh-functions/ /home/agent/.config/zsh/
COPY shell-configs/claude-status-line/ /home/agent/.config/claude-status-line/

# Pre-download zjstatus/zjframes WASM plugins and rewrite configs to local paths
RUN mkdir -p /home/agent/.config/zellij/plugins \
    && curl -fsSL "https://github.com/dj95/zjstatus/releases/latest/download/zjstatus.wasm" \
         -o /home/agent/.config/zellij/plugins/zjstatus.wasm \
    && curl -fsSL "https://github.com/dj95/zjstatus/releases/latest/download/zjframes.wasm" \
         -o /home/agent/.config/zellij/plugins/zjframes.wasm \
    && sed -i 's|https://github.com/dj95/zjstatus/releases/latest/download/zjstatus.wasm|file:/home/agent/.config/zellij/plugins/zjstatus.wasm|g' \
         /home/agent/.config/zellij/layouts/default.kdl \
    && sed -i 's|https://github.com/dj95/zjstatus/releases/latest/download/zjframes.wasm|file:/home/agent/.config/zellij/plugins/zjframes.wasm|g' \
         /home/agent/.config/zellij/config.kdl \
    && sed -i '/^copy_command/d' /home/agent/.config/zellij/config.kdl \
    && sed -i 's/^mouse_mode true/mouse_mode false/' /home/agent/.config/zellij/config.kdl \
    && sed -i 's|file:~/.config/zellij/plugins/zellij-attention.wasm|file:/home/agent/.config/zellij/plugins/zellij-attention.wasm|g' \
         /home/agent/.config/zellij/config.kdl

# ---------------------------------------------------------------------------
# Zsh configuration
# ---------------------------------------------------------------------------
RUN cat > /home/agent/.zshrc <<'EOZSH'
# Ensure plugins are enabled (Docker sandbox overwrites settings.json on creation)
[ -x ~/.local/bin/ensure-plugins.sh ] && ~/.local/bin/ensure-plugins.sh

# Starship prompt
eval "$(starship init zsh)"

# PATH
export PATH="$HOME/.local/bin:$PATH"

# Editor
export EDITOR=nvim
export VISUAL=nvim

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias vi='nvim'
alias vim='nvim'
alias nv='nvim'
alias ga='git add'
alias gc='git commit'
alias gcm='git commit -m'
alias gs='git status'
alias gco='git checkout'
alias gp='git push'
alias gpu='git push -u'

# Source custom functions
[ -f ~/.config/zsh/functions.zsh ] && source ~/.config/zsh/functions.zsh
EOZSH

# ---------------------------------------------------------------------------
# claude-multiagent plugin (from builder stage)
# ---------------------------------------------------------------------------
COPY --from=builder /plugin-cache/ /home/agent/.claude/plugins/

# Ensure enabledPlugins is merged into settings.json at startup
# (Docker sandbox overwrites settings.json on creation, so we merge at runtime)
RUN cat > /home/agent/.local/bin/ensure-plugins.sh <<'EOSCRIPT'
#!/bin/sh
# Idempotency guard — skip if already run this session
[ -f /tmp/.ensure-plugins-done ] && return 0 2>/dev/null || [ -f /tmp/.ensure-plugins-done ] && exit 0

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"

# ---------------------------------------------------------------------------
# Install credentials — try three sources in order:
#   1. Keychain-extracted temp file (clauded-creds.*) mounted by clauded()
#   2. Host-mounted ~/.claude/.credentials.json (legacy)
#   3. Skip (user will be prompted to authenticate)
# ---------------------------------------------------------------------------
CREDS_DEST="$HOME/.claude/.credentials.json"
if [ ! -f "$CREDS_DEST" ]; then
  # Source 1: keychain-extracted credentials (staging dir mounted by clauded)
  CREDS_TMP=$(find / -maxdepth 4 -name "clauded-creds" -type f 2>/dev/null | head -1)
  if [ -n "$CREDS_TMP" ]; then
    cp "$CREDS_TMP" "$CREDS_DEST"
    chmod 600 "$CREDS_DEST"
  else
    # Source 2: host-mounted ~/.claude/.credentials.json
    HOST_CRED=$(find / -maxdepth 5 -path "*/.claude/.credentials.json" -type f \
                  ! -path "$CREDS_DEST" 2>/dev/null | head -1)
    if [ -n "$HOST_CRED" ]; then
      cp "$HOST_CRED" "$CREDS_DEST"
      chmod 600 "$CREDS_DEST"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Install host-mounted config files from ~/.claude (mounted read-only by clauded)
# The host ~/.claude dir is mounted at its original path (e.g. /Users/<user>/.claude).
# ---------------------------------------------------------------------------
HOST_CLAUDE_DIR=$(find / -maxdepth 5 -path "*/.claude/CLAUDE.md" -type f \
                    ! -path "$HOME/.claude/CLAUDE.md" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
if [ -n "$HOST_CLAUDE_DIR" ]; then
  # Global CLAUDE.md
  if [ -f "$HOST_CLAUDE_DIR/CLAUDE.md" ]; then
    cp "$HOST_CLAUDE_DIR/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  fi
  # Statusline script
  if [ -f "$HOST_CLAUDE_DIR/statusline.sh" ]; then
    cp "$HOST_CLAUDE_DIR/statusline.sh" "$HOME/.config/claude-status-line/statusline.sh"
    chmod +x "$HOME/.config/claude-status-line/statusline.sh"
  fi
fi

# ---------------------------------------------------------------------------
# gh CLI config (mounted read-only by clauded from host ~/.config/gh)
# Enables git push via HTTPS without re-authenticating each session.
# ---------------------------------------------------------------------------
HOST_GH=$(find / -maxdepth 6 -path "*/.config/gh/hosts.yml" -type f \
            ! -path "$HOME/.config/gh/hosts.yml" 2>/dev/null | head -1)
HOST_GH_DIR=""
[ -n "$HOST_GH" ] && HOST_GH_DIR=$(dirname "$HOST_GH")
if [ -n "$HOST_GH_DIR" ]; then
  mkdir -p "$HOME/.config/gh"
  cp "$HOST_GH_DIR"/*.yml "$HOME/.config/gh/" 2>/dev/null
  chmod 600 "$HOME/.config/gh"/*.yml 2>/dev/null
fi

# ---------------------------------------------------------------------------
# OAuth token from host's .sandbox-token (created by clauded setup-token flow)
# The host ~/.claude is mounted read-only, so we can read the token directly.
# Docker sandbox ignores ENTRYPOINT (PID 1 is sleep infinity), so env vars
# exported here only affect Bash tool invocations via CLAUDE_ENV_FILE.
# For Claude's own auth, we must write CLAUDE_CODE_OAUTH_TOKEN to the
# persistent env file so it's available when Claude's process reads it.
# ---------------------------------------------------------------------------
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] && [ -n "$HOST_CLAUDE_DIR" ]; then
  SANDBOX_TOKEN_FILE="$HOST_CLAUDE_DIR/.sandbox-token"
  if [ -f "$SANDBOX_TOKEN_FILE" ]; then
    CLAUDE_CODE_OAUTH_TOKEN=$(cat "$SANDBOX_TOKEN_FILE")
    export CLAUDE_CODE_OAUTH_TOKEN
  fi
fi
# Persist the token to CLAUDE_ENV_FILE so Claude's Bash tool and process can use it
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  PERSISTENT_ENV="${CLAUDE_ENV_FILE:-/etc/sandbox-persistent.sh}"
  if [ -f "$PERSISTENT_ENV" ] && ! grep -qF "CLAUDE_CODE_OAUTH_TOKEN" "$PERSISTENT_ENV" 2>/dev/null; then
    printf 'export CLAUDE_CODE_OAUTH_TOKEN="%s"\n' "$CLAUDE_CODE_OAUTH_TOKEN" >> "$PERSISTENT_ENV"
  fi
fi

# Env vars passed via clauded -e KEY=VALUE (mounted as temp file)
ENV_FILE=$(find /var/folders /tmp -maxdepth 5 -name "clauded-env.*" -type f 2>/dev/null | head -1)
if [ -n "$ENV_FILE" ] && ! grep -qF "# clauded-env-loaded" "${CLAUDE_ENV_FILE:-/etc/sandbox-persistent.sh}" 2>/dev/null; then
  . "$ENV_FILE"
  PERSISTENT_ENV="${CLAUDE_ENV_FILE:-/etc/sandbox-persistent.sh}"
  if [ -f "$PERSISTENT_ENV" ]; then
    grep -v '^#!' "$ENV_FILE" >> "$PERSISTENT_ENV"
    printf '# clauded-env-loaded\n' >> "$PERSISTENT_ENV"
  fi
fi

# When CLAUDE_CODE_OAUTH_TOKEN is set, ensure onboarding is marked complete
# so Claude doesn't prompt for interactive setup despite having a valid token.
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  CLAUDE_JSON="$HOME/.claude.json"
  if [ ! -f "$CLAUDE_JSON" ] || ! grep -q '"hasCompletedOnboarding"' "$CLAUDE_JSON" 2>/dev/null; then
    if command -v jq >/dev/null 2>&1 && [ -f "$CLAUDE_JSON" ]; then
      jq '.hasCompletedOnboarding = true' "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" \
        && mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
    else
      printf '{"hasCompletedOnboarding":true}\n' > "$CLAUDE_JSON"
    fi
  fi
fi

# specify — inject CLAUDE.md docs so Claude knows about the tool
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
SPECIFY_MARKER="<!-- BEGIN SPECIFY -->"
if [ -x /usr/local/bin/sp ] && ! grep -qF "$SPECIFY_MARKER" "$CLAUDE_MD" 2>/dev/null; then
  mkdir -p "$(dirname "$CLAUDE_MD")"
  cat >> "$CLAUDE_MD" <<'EOSPECIFY'

<!-- BEGIN SPECIFY -->
## Specify — spec-based functional verification

The `sp` command (aliased from `specify`) is available in this sandbox. It turns functional requirements into machine-verifiable specs.

### Quick reference

```bash
sp spec guide              # authoring guide
sp spec lint --spec app.spec.yaml
sp spec validate --spec app.spec.yaml --capture ./captures
sp cli run --spec app.spec.yaml --output report/
sp spec generate           # infer spec from captures
sp spec evolve             # find gaps, suggest improvements
sp spec export             # generate Playwright/Cypress tests
sp mcp                     # start MCP server
sp agent run               # autonomous headless verification
```

### Key commands

| Command | What |
|---------|------|
| `spec validate` | Gap analysis: spec vs captured behavior |
| `spec generate` | Infer a spec from capture data |
| `spec evolve` | Find gaps and suggest spec improvements |
| `spec lint` | Structural validation (no captures needed) |
| `spec export` | Generate Playwright or Cypress tests from spec |
| `spec import` | Import existing e2e tests as spec items |
| `spec sync` | Bidirectional diff: spec vs e2e tests |
| `cli run` | Run CLI commands defined in spec, validate output |
| `agent run` | Autonomous headless verification |
| `mcp` | MCP server for LLM clients |

The specify project source is at /home/agent/projects/specify. Spec format is YAML or JSON. Reports include expected vs actual evidence for every assertion (JSON, Markdown, or HTML output).
<!-- END SPECIFY -->
EOSPECIFY
fi

# ---------------------------------------------------------------------------
# Merge plugin + statusLine + MCP settings into settings.json
# ---------------------------------------------------------------------------
MERGE_OBJ='{"enabledPlugins":{"claude-multiagent@gm2211-plugins":true,"ralph-loop@claude-plugins-official":true,"feature-dev@claude-plugins-official":true},"statusLine":{"type":"command","command":"~/.config/claude-status-line/statusline.sh"}}'

# Add DigitalOcean MCP server if API token is available
if [ -n "$DIGITALOCEAN_API_TOKEN" ]; then
  MERGE_OBJ=$(printf '%s' "$MERGE_OBJ" | jq --arg token "$DIGITALOCEAN_API_TOKEN" \
    '. + {"mcpServers":{"digitalocean":{"command":"npx","args":["-y","@digitalocean/mcp"],"env":{"DIGITALOCEAN_API_TOKEN":$token}}}}')
fi

if [ ! -f "$SETTINGS" ]; then
  printf '%s\n' "$MERGE_OBJ" > "$SETTINGS"
elif command -v jq >/dev/null 2>&1; then
  # Merge: existing settings take precedence for statusLine if already set,
  # but always ensure enabledPlugins and statusLine are present
  jq --argjson merge "$MERGE_OBJ" '$merge * .' "$SETTINGS" > "${SETTINGS}.tmp" \
    && mv "${SETTINGS}.tmp" "$SETTINGS"
else
  # Fallback without jq: inject keys if missing
  if ! grep -q '"enabledPlugins"' "$SETTINGS" 2>/dev/null; then
    sed -i 's/}$/,"enabledPlugins":{"claude-multiagent@gm2211-plugins":true,"ralph-loop@claude-plugins-official":true,"feature-dev@claude-plugins-official":true}}/' "$SETTINGS"
  fi
  if ! grep -q '"statusLine"' "$SETTINGS" 2>/dev/null; then
    sed -i 's/}$/,"statusLine":{"type":"command","command":"~\/.config\/claude-status-line\/statusline.sh"}}/' "$SETTINGS"
  fi
fi

touch /tmp/.ensure-plugins-done

EOSCRIPT
RUN chmod +x /home/agent/.local/bin/ensure-plugins.sh

# ---------------------------------------------------------------------------
# Claude wrapper — lives in ~/.local/bin which is first on PATH, so it
# shadows the npm-installed binary and survives npm updates.
# Runs ensure-plugins.sh and updates claude before launching.
# ---------------------------------------------------------------------------
RUN <<'WRAPPER_SCRIPT'
set -eux
REAL_CLAUDE=$(which claude)

cat > /home/agent/.local/bin/claude <<EOWRAPPER
#!/bin/sh
if [ ! -f /tmp/.ensure-plugins-done ] && [ -x /home/agent/.local/bin/ensure-plugins.sh ]; then
  . /home/agent/.local/bin/ensure-plugins.sh
fi
# Update Claude Code once per session (timeout after 30s to avoid hanging)
if [ ! -f /tmp/.claude-updated ]; then
  timeout 30 npm update -g @anthropic-ai/claude-code >/tmp/claude-update.log 2>&1 || true
  touch /tmp/.claude-updated
fi
exec ${REAL_CLAUDE} "\$@"
EOWRAPPER
chmod +x /home/agent/.local/bin/claude
WRAPPER_SCRIPT

# beads-tui Python venv
RUN set -eux; \
    VERSION=$(cat /home/agent/.claude/plugins/.plugin-version); \
    BEADS_TUI_DIR="/home/agent/.claude/plugins/cache/gm2211-plugins/claude-multiagent/${VERSION}/scripts/beads-tui"; \
    VENV_DIR="/home/agent/.claude/plugins/cache/gm2211-plugins/claude-multiagent/${VERSION}/scripts/.beads-tui-venv"; \
    python3 -m venv "${VENV_DIR}"; \
    "${VENV_DIR}/bin/pip" install --no-cache-dir "textual>=8.0.0"; \
    if [ -f "${BEADS_TUI_DIR}/pyproject.toml" ]; then \
        "${VENV_DIR}/bin/pip" install --no-cache-dir "${BEADS_TUI_DIR}"; \
    fi

# ---------------------------------------------------------------------------
# Git credential helper — use gh CLI for HTTPS auth (needs GH_TOKEN env var)
# ---------------------------------------------------------------------------
RUN git config --system credential.helper '!/usr/bin/gh auth git-credential' \
    && git config --system url."https://github.com/".insteadOf "git@github.com:"

# ---------------------------------------------------------------------------
# Fix ownership
# ---------------------------------------------------------------------------
RUN chown -R agent:agent /home/agent

# ---------------------------------------------------------------------------
# Persistent env file — sourced by Claude's bash tool via CLAUDE_ENV_FILE
# and by ensure-plugins.sh at zsh startup.  Includes PATH so that tools
# installed to ~/.local/bin (e.g. sp) are available to Claude.
# ---------------------------------------------------------------------------
RUN printf '%s\n' \
      'export PATH="$HOME/.local/bin:$PATH"' \
      'if [ ! -f /tmp/.ensure-plugins-done ] && [ -x ~/.local/bin/ensure-plugins.sh ]; then' \
      '  . ~/.local/bin/ensure-plugins.sh' \
      '  touch /tmp/.ensure-plugins-done' \
      'fi' \
    > /etc/sandbox-persistent.sh \
    && chmod 666 /etc/sandbox-persistent.sh

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV TERM=xterm-256color
ENV COLORTERM=truecolor
ENV SHELL=/bin/zsh
ENV CLAUDE_ENV_FILE=/etc/sandbox-persistent.sh

USER agent
