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
# Kitty terminfo (for TERM=xterm-kitty from host)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://raw.githubusercontent.com/kovidgoyal/kitty/master/terminfo/kitty.terminfo \
        | tic -x -o /usr/share/terminfo -

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
         /home/agent/.config/zellij/layouts/default.kdl \
    && sed -i 's|https://github.com/dj95/zjstatus/releases/latest/download/zjframes.wasm|file:/home/agent/.config/zellij/plugins/zjframes.wasm|g' \
         /home/agent/.config/zellij/config.kdl \
    && sed -i '/^copy_command/d' /home/agent/.config/zellij/config.kdl \
    && sed -i 's|file:~/.config/zellij/plugins/zellij-attention.wasm|file:/home/agent/.config/zellij/plugins/zellij-attention.wasm|g' \
         /home/agent/.config/zellij/config.kdl

# ---------------------------------------------------------------------------
# Zsh configuration
# ---------------------------------------------------------------------------
RUN cat > /home/agent/.zshrc <<'EOZSH'
# Ensure plugins are enabled (Docker sandbox overwrites settings.json on creation)
[ -x ~/.local/bin/ensure-plugins.sh ] && ~/.local/bin/ensure-plugins.sh

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
# Install host-mounted config files from ~/.claude (mounted read-only by clauded)
# The host ~/.claude dir is mounted at its original path (e.g. /Users/<user>/.claude).
# ---------------------------------------------------------------------------
HOST_CLAUDE_DIR=$(find /Users /home -maxdepth 3 -path "*/.claude/.credentials.json" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
if [ -n "$HOST_CLAUDE_DIR" ] && [ "$HOST_CLAUDE_DIR" != "$HOME/.claude" ]; then
  # Credentials → avoids re-auth each session
  if [ -f "$HOST_CLAUDE_DIR/.credentials.json" ]; then
    cp "$HOST_CLAUDE_DIR/.credentials.json" "$HOME/.claude/.credentials.json"
    chmod 600 "$HOME/.claude/.credentials.json"
  fi
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

# Env vars passed via clauded -e KEY=VALUE (mounted as temp file)
ENV_FILE=$(find /var/folders /tmp -maxdepth 2 -name "clauded-env.*" -type f 2>/dev/null | head -1)
if [ -n "$ENV_FILE" ] && ! grep -qF "# clauded-env-loaded" "${CLAUDE_ENV_FILE:-/etc/sandbox-persistent.sh}" 2>/dev/null; then
  . "$ENV_FILE"
  PERSISTENT_ENV="${CLAUDE_ENV_FILE:-/etc/sandbox-persistent.sh}"
  if [ -f "$PERSISTENT_ENV" ]; then
    grep -v '^#!' "$ENV_FILE" >> "$PERSISTENT_ENV"
    printf '# clauded-env-loaded\n' >> "$PERSISTENT_ENV"
  fi
fi

# sp (specify) — symlink if the workspace is mounted
if [ ! -x "$HOME/.local/bin/sp" ]; then
  SP_RUN=$(find /Users /home -maxdepth 5 -path "*/specify/run.sh" -type f 2>/dev/null | head -1)
  if [ -n "$SP_RUN" ]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$SP_RUN" "$HOME/.local/bin/sp"
  fi
fi

# ---------------------------------------------------------------------------
# Merge plugin + statusLine settings into settings.json
# ---------------------------------------------------------------------------
MERGE_OBJ='{"enabledPlugins":{"claude-multiagent@gm2211-plugins":true},"statusLine":{"type":"command","command":"~/.config/claude-status-line/statusline.sh"}}'

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
    sed -i 's/}$/,"enabledPlugins":{"claude-multiagent@gm2211-plugins":true}}/' "$SETTINGS"
  fi
  if ! grep -q '"statusLine"' "$SETTINGS" 2>/dev/null; then
    sed -i 's/}$/,"statusLine":{"type":"command","command":"~\/.config\/claude-status-line\/statusline.sh"}}/' "$SETTINGS"
  fi
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
