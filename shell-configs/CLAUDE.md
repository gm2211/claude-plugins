# Shell Configs Install Guide

Terminal setup: kitty + zellij with Catppuccin Mocha theme, Fira Code font, and Cmd-based keybindings for macOS.

> **Important:** Always prompt the user for confirmation before installing, symlinking, or overwriting any of these configs. Never install anything automatically.

## Prerequisites

```bash
brew install kitty zellij lazygit
brew install --cask font-symbols-only-nerd-font font-meslo-lg-nerd-font
```

zjstatus (Zellij status bar plugin) is auto-downloaded as a WASM plugin from the layout config on first launch — no manual install needed.

- **kitty** -- terminal emulator
- **zellij** -- terminal multiplexer (replaces tmux)
- **lazygit** -- TUI git client (used by lazygit.nvim)
- **font-symbols-only-nerd-font** -- Nerd Font symbols used by kitty's `symbol_map` for icons in nvim, lualine, neo-tree, etc.
- **font-meslo-lg-nerd-font** -- Meslo LG Nerd Font (patched monospace font with glyphs)

If you don't already have Fira Code installed:

```bash
brew install --cask font-fira-code
```

## Config file locations

| Repo path | Installs to |
|-----------|-------------|
| `kitty/kitty.conf` | `~/.config/kitty/kitty.conf` |
| `zellij/config.kdl` | `~/.config/zellij/config.kdl` |
| `zellij/layouts/default.kdl` | `~/.config/zellij/layouts/default.kdl` |
| `nvim/` | `~/.config/nvim/` |
| `claude-status-line/statusline.sh` | `~/.config/claude-status-line/statusline.sh` |

## Quick install

```bash
# Install dependencies
brew install kitty zellij lazygit
brew install --cask font-symbols-only-nerd-font font-meslo-lg-nerd-font font-fira-code

# Create config directories
mkdir -p ~/.config/kitty ~/.config/zellij/layouts ~/.config/nvim ~/.config/claude-status-line

# Symlink configs (adjust REPO_DIR to your clone location)
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ln -sf "$REPO_DIR/kitty/kitty.conf" ~/.config/kitty/kitty.conf
ln -sf "$REPO_DIR/zellij/config.kdl" ~/.config/zellij/config.kdl
ln -sf "$REPO_DIR/zellij/layouts/default.kdl" ~/.config/zellij/layouts/default.kdl

# Nvim config (symlink the whole directory's contents)
for f in init.lua lua; do
  ln -sf "$REPO_DIR/nvim/$f" ~/.config/nvim/"$f"
done

# Claude Code status line
cp "$REPO_DIR/claude-status-line/statusline.sh" ~/.config/claude-status-line/statusline.sh
chmod +x ~/.config/claude-status-line/statusline.sh

# Reload kitty config (if kitty is already running)
kill -SIGUSR1 $(pgrep kitty) 2>/dev/null
```

## Keybinding reference

### Pane focus (works in any zellij mode)

| Key | Action |
|-----|--------|
| `Cmd+h` | Focus pane left |
| `Cmd+j` | Focus pane down |
| `Cmd+k` | Focus pane up |

### Zellij modes (Cmd = Super)

| Key | Mode |
|-----|------|
| `Cmd+p` | Pane mode |
| `Cmd+t` | Tab mode |
| `Cmd+n` | Resize mode |
| `Cmd+g` | Move mode (move panes around) |
| `Cmd+s` | Scroll mode |
| `Cmd+y` | Session mode |
| `Cmd+l` | Locked mode (pass keys to inner session) |
| `Cmd+q` | Quit zellij |
| `Cmd+c` | Copy |

### Terminal navigation (via kitty keymaps)

| Key | Action |
|-----|--------|
| `Cmd+Left/Right` | Home / End (beginning/end of line) |
| `Alt+Left/Right` | Word navigation |
| `Alt+Backspace` | Delete word |
| `Cmd+Backspace` | Delete line |
| `Cmd+v` | Paste |

### Kitty notes

- **Theme:** Catppuccin Mocha
- **Font:** Fira Code 14pt with Nerd Font symbols
- **Background:** semi-transparent (0.85 opacity) with blur
- **Tab bar:** hidden (zellij handles tabs)
- **`macos_option_as_alt yes`** -- required for Alt keybinds to pass through to zellij

## Claude worktree function

`shell-configs/zsh-functions/functions.zsh` defines a `claude()` shell function that intercepts the `claude` command when you are on the default branch (main/master) of a git repo and offers to create or switch to a worktree first. This prevents accidental work directly on main.

### Setup

Copy `functions.zsh` to your local config and source it from your `.zshrc` (this also includes the `ss` function and any future additions):

```bash
# First, copy the file to your config directory
cp /path/to/claude-plugins/shell-configs/zsh-functions/functions.zsh ~/.config/zsh/functions.zsh

# Then, add this to your ~/.zshrc
source ~/.config/zsh/functions.zsh
```

For detailed setup instructions, see [ZSH Functions — Installation Instructions](./zsh-functions/CLAUDE.md).

### How it works

- **Not a git repo** → passes through to `command claude` directly
- **Already in a worktree** → passes through to `command claude` directly
- **On a non-default branch** → passes through to `command claude` directly
- **On main/master** → shows a menu of existing `.worktrees/` subdirectories (skipping task worktrees with `--` in the name), or offers to create a new one with a date-based session name (or custom name)

The function uses `command claude` to call the real claude binary, bypassing the shell function itself.

## Claude Code status line

`shell-configs/claude-status-line/statusline.sh` is a script that formats a single-line status bar for Claude Code. It reads session JSON from stdin and displays: model name, context window usage (colored progress bar), session cost, git info (repo, branch, worktree, files changed, additions/deletions), sandbox mode, working directory, and current time.

### Setup

1. Copy the script to your local config:

```bash
mkdir -p ~/.config/claude-status-line
cp /path/to/claude-plugins/shell-configs/claude-status-line/statusline.sh ~/.config/claude-status-line/statusline.sh
chmod +x ~/.config/claude-status-line/statusline.sh
```

2. Add the status line to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.config/claude-status-line/statusline.sh"
  }
}
```

Requires `jq` to be installed (`brew install jq`).

### Config file location

| Repo path | Installs to |
|-----------|-------------|
| `claude-status-line/statusline.sh` | `~/.config/claude-status-line/statusline.sh` |

## Troubleshooting

**Missing icons (boxes in statusline):**
Install `font-symbols-only-nerd-font` and reload kitty:
```bash
kill -SIGUSR1 $(pgrep kitty)
```

**Cmd+key not working in zellij:**
The key must be unmapped in kitty.conf first. Add `map cmd+<key>` with no action to pass it through to zellij via the kitty keyboard protocol.

**Kitty config reload:**
```bash
kill -SIGUSR1 $(pgrep kitty)
# or
kitty @ load-config
```

**Zellij config changes:**
Requires a zellij session restart -- config reload alone won't pick up changes.
