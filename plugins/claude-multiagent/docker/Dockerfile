# =============================================================================
# Claude Code Dev Environment with claude-multiagent plugin
# =============================================================================
# Build context: repo root (docker build -f plugins/claude-multiagent/docker/Dockerfile .)
# Multi-arch: supports linux/amd64 and linux/arm64 via TARGETARCH
# =============================================================================

# =============================================================================
# Stage 1: Builder — download binaries & prepare plugin cache
# =============================================================================
FROM ubuntu:24.04 AS builder

SHELL ["/bin/bash", "-c"]

ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 1. Download bd (beads) binary v0.56.1
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL "https://github.com/steveyegge/beads/releases/download/v0.56.1/beads_0.56.1_linux_${TARGETARCH}.tar.gz" \
        | tar xz -C /tmp; \
    mv /tmp/bd /bd; \
    chmod +x /bd

# ---------------------------------------------------------------------------
# 2. Clone the plugin marketplace repo & init submodules
# ---------------------------------------------------------------------------
RUN git clone https://github.com/gm2211/claude-plugins.git /plugin-src \
    && cd /plugin-src \
    && git submodule update --init --recursive || true

# ---------------------------------------------------------------------------
# 3. Build the plugin cache directory structure
# ---------------------------------------------------------------------------
RUN <<'BUILDER_SCRIPT'
set -eux
VERSION=$(jq -r '.plugins[] | select(.name=="claude-multiagent") | .version' \
          /plugin-src/.claude-plugin/marketplace.json)
echo "Plugin version: ${VERSION}"

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
        "installPath": "/home/claude/.claude/plugins/cache/gm2211-plugins/claude-multiagent/${VERSION}",
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
    "installLocation": "/home/claude/.claude/plugins/marketplaces/gm2211-plugins",
    "lastUpdated": "2026-01-01T00:00:00.000Z"
  }
}
EOJSON

echo "${VERSION}" > /plugin-cache/.plugin-version
BUILDER_SCRIPT


# =============================================================================
# Stage 2: Runtime — full dev environment
# =============================================================================
FROM ubuntu:24.04 AS runtime

ARG TARGETARCH

SHELL ["/bin/bash", "-c"]

# ---------------------------------------------------------------------------
# System packages + locale
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        python3 \
        python3-pip \
        python3-venv \
        zsh \
        unzip \
        wget \
        sudo \
        locales \
        xclip \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Node.js 22 LTS (via NodeSource)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# GitHub CLI
# ---------------------------------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Claude Code (global npm package)
# ---------------------------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code

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
# Neovim (stable v0.10.x tarball, multi-arch)
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
# Starship prompt
# ---------------------------------------------------------------------------
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- -y

# ---------------------------------------------------------------------------
# Create 'claude' user (uid 1000, zsh shell)
# ---------------------------------------------------------------------------
# Remove existing uid 1000 user if present (ubuntu:24.04 has 'ubuntu'), then create 'claude'
RUN if id -u 1000 &>/dev/null; then userdel -r "$(id -nu 1000)" 2>/dev/null || true; fi \
    && useradd -m -s /bin/zsh -u 1000 claude

# ---------------------------------------------------------------------------
# Copy shell configs from build context
# ---------------------------------------------------------------------------
COPY shell-configs/zellij/  /home/claude/.config/zellij/
COPY shell-configs/nvim/    /home/claude/.config/nvim/
COPY shell-configs/zsh-functions/ /home/claude/.config/zsh/
COPY shell-configs/claude-status-line/ /home/claude/.config/claude-status-line/

# ---------------------------------------------------------------------------
# No-op pbcopy wrapper (Zellij config references pbcopy; no X11 in container)
# ---------------------------------------------------------------------------
RUN printf '#!/bin/sh\ncat > /dev/null\n' > /usr/local/bin/pbcopy \
    && chmod +x /usr/local/bin/pbcopy

# ---------------------------------------------------------------------------
# Zsh configuration
# ---------------------------------------------------------------------------
RUN cat > /home/claude/.zshrc <<'EOZSH'
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
alias cc='claude --dangerously-skip-permissions'
alias vi='nvim'
alias vim='nvim'

# Source custom functions
[ -f ~/.config/zsh/functions.zsh ] && source ~/.config/zsh/functions.zsh

# Beads
export PATH="$HOME/.local/bin:$PATH"
EOZSH

# ---------------------------------------------------------------------------
# Copy artifacts from builder stage
# ---------------------------------------------------------------------------
COPY --from=builder /bd /home/claude/.local/bin/bd
COPY --from=builder /plugin-cache/ /home/claude/.claude/plugins/

# ---------------------------------------------------------------------------
# Python venv for beads-tui (installed from the submodule's pyproject.toml)
# ---------------------------------------------------------------------------
RUN set -eux; \
    VERSION=$(cat /home/claude/.claude/plugins/.plugin-version); \
    BEADS_TUI_DIR="/home/claude/.claude/plugins/cache/gm2211-plugins/claude-multiagent/${VERSION}/scripts/beads-tui"; \
    VENV_DIR="/home/claude/.claude/plugins/cache/gm2211-plugins/claude-multiagent/${VERSION}/scripts/.beads-tui-venv"; \
    python3 -m venv "${VENV_DIR}"; \
    "${VENV_DIR}/bin/pip" install --no-cache-dir "textual>=8.0.0"; \
    if [ -f "${BEADS_TUI_DIR}/pyproject.toml" ]; then \
        "${VENV_DIR}/bin/pip" install --no-cache-dir "${BEADS_TUI_DIR}"; \
    fi

# ---------------------------------------------------------------------------
# Entrypoint & final setup
# ---------------------------------------------------------------------------
COPY plugins/claude-multiagent/docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Fix ownership of all home directory contents
RUN chown -R claude:claude /home/claude

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV TERM=xterm-256color
ENV PATH="/home/claude/.local/bin:${PATH}"

USER claude
WORKDIR /home/claude
ENTRYPOINT ["/entrypoint.sh"]
