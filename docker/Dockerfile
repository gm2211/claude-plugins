# =============================================================================
# Custom Docker Sandbox Template — extends the official Claude Code base
# =============================================================================
# Build:  docker build -t gm-claude-dev -f docker/Dockerfile .
# Use:    docker sandbox run -t gm-claude-dev claude .
# =============================================================================

# =============================================================================
# Stage 1: Builder — prepare claude-multiagent plugin cache
# =============================================================================
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/gm2211/claude-plugins.git /plugin-src \
    && cd /plugin-src \
    && git submodule update --init --recursive

RUN <<'BUILDER_SCRIPT'
set -eux
VERSION=$(jq -r '.plugins[] | select(.name=="claude-multiagent") | .version' \
          /plugin-src/.claude-plugin/marketplace.json)

CACHE_DIR="/plugin-cache/cache/gm2211-plugins/claude-multiagent/${VERSION}"
mkdir -p "${CACHE_DIR}"
cp -a /plugin-src/plugins/claude-multiagent/. "${CACHE_DIR}/"

cat > /plugin-cache/installed_plugins.json <<EOJSON
{
  "version": 2,
  "plugins": {
    "claude-multiagent@gm2211-plugins": [
      {
        "scope": "user",
        "installPath": "/home/agent/.claude/plugins/cache/gm2211-plugins/claude-multiagent/${VERSION}",
        "version": "${VERSION}",
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
  "gm2211-plugins": {
    "source": {
      "source": "github",
      "repo": "gm2211/claude-plugins"
    },
    "installLocation": "/home/agent/.claude/plugins/marketplaces/gm2211-plugins",
    "lastUpdated": "2026-01-01T00:00:00.000Z"
  }
}
EOJSON

echo "${VERSION}" > /plugin-cache/.plugin-version
BUILDER_SCRIPT

# =============================================================================
# Stage 2: Custom sandbox template
# =============================================================================
FROM docker/sandbox-templates:claude-code

USER root

ARG TARGETARCH

# ---------------------------------------------------------------------------
# System packages beyond the base image
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        zsh \
        ruby ruby-dev \
        build-essential \
        unzip \
        socat \
        uuid-runtime \
        postgresql-client \
        python3-venv \
        openssh-client \
        locales \
        fontconfig \
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
# Rust / Cargo (installed to /home/agent; chown happens later)
# ---------------------------------------------------------------------------
ENV RUSTUP_HOME=/home/agent/.rustup
ENV CARGO_HOME=/home/agent/.cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# ---------------------------------------------------------------------------
# doctl (DigitalOcean CLI)
# ---------------------------------------------------------------------------
RUN set -eux; \
    DOCTL_VERSION=$(curl -fsSL https://api.github.com/repos/digitalocean/doctl/releases/latest | jq -r '.tag_name' | sed 's/^v//'); \
    curl -fsSL "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-${TARGETARCH}.tar.gz" \
        | tar xz -C /usr/local/bin; \
    chmod +x /usr/local/bin/doctl

# ---------------------------------------------------------------------------
# kubectl
# ---------------------------------------------------------------------------
RUN set -eux; \
    KUBE_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt); \
    curl -fsSL "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
        -o /usr/local/bin/kubectl; \
    chmod +x /usr/local/bin/kubectl

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $VERSION_CODENAME) main" \
        | tee /etc/apt/sources.list.d/hashicorp.list; \
    apt-get update && apt-get install -y --no-install-recommends terraform \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Kitty terminfo (for TERM=xterm-kitty from host)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://raw.githubusercontent.com/kovidgoyal/kitty/master/terminfo/kitty.terminfo \
        | tic -x -o /usr/share/terminfo -

# ---------------------------------------------------------------------------
# OpenAI Codex CLI
# ---------------------------------------------------------------------------
RUN npm install -g @openai/codex

# ---------------------------------------------------------------------------
# Starship prompt
# ---------------------------------------------------------------------------
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- -y

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
         /home/agent/.config/zellij/layouts/modern.kdl \
    && sed -i 's|https://github.com/dj95/zjstatus/releases/latest/download/zjframes.wasm|file:/home/agent/.config/zellij/plugins/zjframes.wasm|g' \
         /home/agent/.config/zellij/config.kdl \
    && sed -i '/^copy_command/d' /home/agent/.config/zellij/config.kdl \
    && sed -i 's|file:~/.config/zellij/plugins/zellij-attention.wasm|file:/home/agent/.config/zellij/plugins/zellij-attention.wasm|g' \
         /home/agent/.config/zellij/config.kdl

# ---------------------------------------------------------------------------
# Zsh configuration
# ---------------------------------------------------------------------------
# Entrypoint wrapper — runs ensure-plugins.sh once before the base image's CMD.
# The base image has no ENTRYPOINT, just CMD ["claude","--dangerously-skip-permissions"].
# Our entrypoint does setup then exec's into whatever CMD the sandbox passes.
RUN cat > /home/agent/.local/bin/entrypoint.sh <<'EOENTRY'
#!/bin/sh
[ -x ~/.local/bin/ensure-plugins.sh ] && ~/.local/bin/ensure-plugins.sh
exec "$@"
EOENTRY
RUN chmod +x /home/agent/.local/bin/entrypoint.sh

RUN cat > /home/agent/.zshrc <<'EOZSH'
# Auto-start zellij on interactive attach (skipped inside existing zellij sessions)
if [[ -z "$ZELLIJ" ]] && [[ $- == *i* ]] && command -v zellij &>/dev/null; then
    exec zellij
fi

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
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"

# ---------------------------------------------------------------------------
# Source env vars staged by clauded() on the host (DOLT_HOST_PORT, tokens, etc.)
# ---------------------------------------------------------------------------
STAGING_ENV=$(find /Users /home -maxdepth 6 -name "clauded-env" -type f 2>/dev/null | head -1)
if [ -f "$STAGING_ENV" ]; then
  . "$STAGING_ENV"
fi

# ---------------------------------------------------------------------------
# Install host-mounted config files from .claude-sandbox-mount/
# (staged by clauded() on the host before sandbox launch)
# ---------------------------------------------------------------------------
MOUNT_DIR=$(find /Users /home -maxdepth 6 -name ".claude-sandbox-mount" -type d 2>/dev/null | head -1)
if [ -n "$MOUNT_DIR" ]; then
  # Global CLAUDE.md → ~/.claude/CLAUDE.md
  if [ -f "$MOUNT_DIR/CLAUDE.md" ]; then
    cp "$MOUNT_DIR/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  fi
  # Host statusline script → overwrite the baked-in one
  if [ -f "$MOUNT_DIR/statusline.sh" ]; then
    cp "$MOUNT_DIR/statusline.sh" "$HOME/.config/claude-status-line/statusline.sh"
    chmod +x "$HOME/.config/claude-status-line/statusline.sh"
  fi
fi

# ---------------------------------------------------------------------------
# Ensure CLAUDE.md includes bd tool documentation
# ---------------------------------------------------------------------------
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [ -f "$CLAUDE_MD" ] && ! grep -q '`bd`' "$CLAUDE_MD" 2>/dev/null; then
  cat >> "$CLAUDE_MD" <<'EOBD'
- `bd` — CLI for Beads issue tracker (backed by Dolt database). Tracks issues/tasks in `.beads/` directories. Run `bd` with no args for usage. Common commands: `bd list`, `bd show <id>`, `bd create`, `bd update`, `bd dolt start` (start the Dolt SQL server if not running).
EOBD
fi

# ---------------------------------------------------------------------------
# Forward host ports into the container via socat.
# clauded() passes SANDBOX_FORWARD_PORTS as a comma-separated list.
# Each port gets a socat forwarder: 127.0.0.1:PORT → host.docker.internal:PORT
# ---------------------------------------------------------------------------
if [ -n "$SANDBOX_FORWARD_PORTS" ]; then
  echo "$SANDBOX_FORWARD_PORTS" | tr ',' '\n' | while read -r FWD_PORT; do
    [ -z "$FWD_PORT" ] && continue
    socat TCP-LISTEN:"$FWD_PORT",bind=127.0.0.1,fork,reuseaddr \
          TCP:host.docker.internal:"$FWD_PORT" &
  done
fi

# Clean stale dolt state from host-mounted .beads/ dirs and write forwarded port
for BEADS_DIR in $(find /Users /home -maxdepth 4 -name ".beads" -type d 2>/dev/null); do
  rm -f "$BEADS_DIR/dolt-server.pid" "$BEADS_DIR/dolt-server.lock" 2>/dev/null
  if [ -n "$SANDBOX_FORWARD_PORTS" ]; then
    # If dolt port (3307) is among forwarded ports, update the port file
    echo "$SANDBOX_FORWARD_PORTS" | tr ',' '\n' | grep -qx 3307 && \
      echo "3307" > "$BEADS_DIR/dolt-server.port"
  fi
done

# sp (specify) — find mounted host repo or clone, then create /usr/local/bin/sp
# Always use a node wrapper (not symlink to specify wrapper) because the host
# repo is mounted read-only and the wrapper's auto-build would fail.
SP_DIR=$(find /Users /home -maxdepth 4 -path "*/projects/specify" -type d -exec test -f "{}/package.json" \; -print 2>/dev/null | head -1)
if [ -z "$SP_DIR" ]; then
  SP_DIR="$HOME/projects/specify"
  git clone https://github.com/gm2211/specify.git "$SP_DIR" 2>/dev/null
  # Build after clone (writable since we own it)
  if [ -f "$SP_DIR/tsconfig.json" ]; then
    (cd "$SP_DIR" && npm install --ignore-scripts 2>/dev/null && ./node_modules/.bin/tsc 2>/dev/null) || true
  fi
fi
if [ -d "$SP_DIR" ] && [ -f "$SP_DIR/dist/src/cli/index.js" ]; then
  cat > /usr/local/bin/sp <<EOSP
#!/bin/sh
exec node "$SP_DIR/dist/src/cli/index.js" "\$@"
EOSP
  chmod +x /usr/local/bin/sp
fi

# ---------------------------------------------------------------------------
# Merge plugin settings into settings.json
# The Docker sandbox copies ~/.claude from the host (including settings.json
# and statusline.sh), so statusLine config comes from the host.
# This merge ensures enabledPlugins and mcpServers are present as a fallback.
# ---------------------------------------------------------------------------
MERGE_OBJ='{"enabledPlugins":{"claude-multiagent@gm2211-plugins":true},"mcpServers":{"digitalocean":{"command":"npx","args":["-y","@digitalocean/mcp"],"env":{"DIGITALOCEAN_API_TOKEN":"${DIGITALOCEAN_API_TOKEN}"}}}}'

if [ ! -f "$SETTINGS" ]; then
  printf '%s\n' "$MERGE_OBJ" > "$SETTINGS"
elif command -v jq >/dev/null 2>&1; then
  jq --argjson merge "$MERGE_OBJ" '. * $merge' "$SETTINGS" > "${SETTINGS}.tmp" \
    && mv "${SETTINGS}.tmp" "$SETTINGS"
fi
EOSCRIPT
RUN chmod +x /home/agent/.local/bin/ensure-plugins.sh

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
# Environment
# ---------------------------------------------------------------------------
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV TERM=xterm-256color
ENV COLORTERM=truecolor
ENV SHELL=/bin/zsh
ENV PATH="/home/agent/.cargo/bin:${PATH}"

USER agent

ENTRYPOINT ["/home/agent/.local/bin/entrypoint.sh"]
