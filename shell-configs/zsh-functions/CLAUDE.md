# ZSH Functions — Installation Instructions

This directory contains portable shell functions to be sourced from `~/.zshrc`.

## How to install

1. **Ensure `pngpaste` is installed** (required by the `ss` function):

   ```bash
   brew install pngpaste
   ```

2. **Copy `functions.zsh` to your config directory:**

   ```bash
   cp /path/to/claude-plugins/shell-configs/zsh-functions/functions.zsh ~/.config/zsh/functions.zsh
   ```

   Create the `~/.config/zsh` directory if it doesn't exist:
   ```bash
   mkdir -p ~/.config/zsh
   ```

3. **Add a source line to `~/.zshrc`:**

   ```bash
   # Portable shell functions from claude-plugins
   source ~/.config/zsh/functions.zsh
   ```

   > **Note:** This file now includes the `claude()` worktree function (previously in `shell-configs/claude-function.sh`). If you had a separate `source .../claude-function.sh` line in your `.zshrc`, remove it — sourcing `functions.zsh` is sufficient.

4. **Reload the shell** (`source ~/.zshrc` or open a new terminal).

## Updating the functions

To update to the latest version of the functions:
1. Pull the latest changes in the `claude-plugins` repo
2. Re-copy `functions.zsh` to `~/.config/zsh/functions.zsh`
3. Reload your shell (`source ~/.zshrc` or open a new terminal)

## What's included

| Function | Description |
|----------|-------------|
| `ss`       | Saves the current clipboard image to a temp file (via `pngpaste`) and copies the file path to the clipboard. |
| `wt`       | Worktree selector menu. On the default branch, lists existing session worktrees and cd's into the chosen one. The menu also includes a built-in delete action (`[delete]`) so you can remove worktrees from the same flow. |
| `wt new`   | Worktree creator subcommand. Offers a date-based session name (`session-YYYY-MM-DD`, with `-N` suffix for duplicates) or accepts a custom name. Creates the worktree and cd's into it. |
| `wt delete [name]` | Worktree remover subcommand. Deletes a worktree under `.worktrees/` (interactive picker if `name` is omitted). Asks for confirmation before delete. |
| `claude`   | Wraps `wt`/`wt new` for Claude Code. On the default branch, tries `wt` (selector) first; if that fails (no worktrees), falls back to `wt new` (creator); then launches Claude inside the chosen worktree. `claude --skip` / `claude -s` bypasses worktree checks and disables claude-multiagent hooks for that launch. |
