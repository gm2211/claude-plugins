# Shell Configs Install Guide

Terminal setup: kitty + zellij with Catppuccin Mocha theme, Fira Code font, and Cmd-based keybindings for macOS.

## Prerequisites

```bash
brew install kitty zellij lazygit
brew install --cask font-symbols-only-nerd-font
```

- **kitty** -- terminal emulator
- **zellij** -- terminal multiplexer (replaces tmux)
- **lazygit** -- TUI git client (used by lazygit.nvim)
- **font-symbols-only-nerd-font** -- Nerd Font symbols used by kitty's `symbol_map` for icons in nvim, lualine, neo-tree, etc.

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

## Quick install

```bash
# Install dependencies
brew install kitty zellij lazygit
brew install --cask font-symbols-only-nerd-font font-fira-code

# Create config directories
mkdir -p ~/.config/kitty ~/.config/zellij/layouts

# Symlink configs (adjust REPO_DIR to your clone location)
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ln -sf "$REPO_DIR/kitty/kitty.conf" ~/.config/kitty/kitty.conf
ln -sf "$REPO_DIR/zellij/config.kdl" ~/.config/zellij/config.kdl
ln -sf "$REPO_DIR/zellij/layouts/default.kdl" ~/.config/zellij/layouts/default.kdl

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
| `Cmd+l` | Focus pane right |

### Zellij modes (Cmd = Super)

| Key | Mode |
|-----|------|
| `Cmd+p` | Pane mode |
| `Cmd+t` | Tab mode |
| `Cmd+n` | Resize mode |
| `Cmd+g` | Move mode (move panes around) |
| `Cmd+s` | Scroll mode |
| `Cmd+y` | Session mode |
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
