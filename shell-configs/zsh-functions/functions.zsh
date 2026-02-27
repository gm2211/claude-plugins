# Portable ZSH functions
# Sourced from claude-plugins/shell-configs/zsh-functions/

function ss() {
    local f="/tmp/ss-${RANDOM}${RANDOM}.png"
    pngpaste "$f" && {
      echo -n "$f" | pbcopy
      echo "Saved & copied: $f"
    }
}

# wt() — Interactive worktree selector (wt), creator (wt new), and remover (wt delete).
#
# Works from any git repo. Dispatches on the first argument:
#
#   wt         — pure selector: lists existing session worktrees, prompts for
#                selection, and cd's into the chosen one.
#   wt new     — creator: offers a date-based session name (session-YYYY-MM-DD)
#                with -N suffix for duplicates. Also accepts custom names.
#                Creates the worktree with `git worktree add` and cd's into it.
#   wt delete [name]
#              — remover: deletes a worktree under .worktrees/. If name is
#                omitted, prompts to select one interactively.
#   wt <other> — usage error.
#
# Common behavior (runs before dispatch):
#   - Not inside a git repository → error, return 1
#   - Already inside a git worktree → print which worktree, return 0
#   - On a non-default branch → print which branch, return 0
#   - On the default branch (main/master): dispatch to subcommand
#
# Compatible with bash and zsh.

wt() {
  #############################################################################
  # Helpers
  #############################################################################

  _wt_msg()  { printf '%s\n' "$*" >&2; }
  _wt_warn() { printf 'WARNING: %s\n' "$*" >&2; }
  _wt_err()  { printf 'ERROR: %s\n' "$*" >&2; }

  local subcmd="${1:-}"
  local subarg="${2:-}"

  # Clean up on Ctrl+C
  trap '_wt_msg ""; _wt_msg "Interrupted."; return 130' INT

  #############################################################################
  # Case 1: Not a git repo → error
  #############################################################################

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _wt_err "Not inside a git repository."
    trap - INT
    return 1
  fi

  #############################################################################
  # Case 2: Already in a worktree → inform and return
  # (except for `wt delete`, which is allowed from worktrees too)
  #############################################################################

  local git_dir git_common_dir abs_git_dir abs_git_common
  git_dir="$(git rev-parse --git-dir 2>/dev/null)"
  git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"

  # Normalize to absolute paths for reliable comparison
  abs_git_dir="$(cd "$git_dir" && pwd)"
  abs_git_common="$(cd "$git_common_dir" && pwd)"

  if [ "$subcmd" != "delete" ] && [ "$abs_git_dir" != "$abs_git_common" ]; then
    local wt_branch
    wt_branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo "(detached)")"
    _wt_msg "Already in a worktree: $wt_branch ($(pwd))"
    trap - INT
    return 0
  fi

  #############################################################################
  # Case 3: On a non-default branch → inform and return
  # (except for `wt delete`, which is branch-agnostic)
  #############################################################################

  local default_branch current_branch
  # Detect the default branch dynamically
  default_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')"
  if [ -z "$default_branch" ]; then
    # Fallback: check if main or master exists
    if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
      default_branch="main"
    elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
      default_branch="master"
    else
      default_branch="main"
    fi
  fi

  current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"

  if [ "$subcmd" != "delete" ] && [ "$current_branch" != "$default_branch" ]; then
    _wt_msg "On branch '$current_branch' (not the default branch)."
    trap - INT
    return 0
  fi

  #############################################################################
  # Case 4: On default branch — dispatch on subcommand
  #############################################################################

  local repo_root worktrees_dir
  repo_root="$(git rev-parse --show-toplevel)"
  worktrees_dir="$repo_root/.worktrees"
  mkdir -p "$worktrees_dir"

  case "$subcmd" in

    ###########################################################################
    # wt new — creator
    ###########################################################################

    new)
      # Generate a default date-based session name with -N suffix for duplicates
      local today
      today="$(date +%Y-%m-%d)"
      local default_name="session-${today}"

      # Check for existing session worktrees with today's date and bump suffix
      if [ -d "$worktrees_dir/$default_name" ]; then
        local suffix=2
        while [ -d "$worktrees_dir/${default_name}-${suffix}" ]; do
          suffix=$((suffix + 1))
        done
        default_name="${default_name}-${suffix}"
      fi

      local wt_name
      printf "Worktree name [%s]: " "$default_name" >&2
      read -r wt_name </dev/tty

      # Use default if user pressed Enter without typing anything
      if [ -z "$wt_name" ]; then
        wt_name="$default_name"
      else
        # Sanitize custom name
        wt_name="$(printf '%s' "$wt_name" | tr '[:upper:]' '[:lower:]' | tr ' _' '--' | tr -cd 'a-z0-9-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//' | cut -c1-40)"
        if [ -z "$wt_name" ]; then
          _wt_err "Worktree name cannot be empty."
          trap - INT
          return 1
        fi
      fi

      local worktree_path="$worktrees_dir/$wt_name"

      # If this worktree already exists, just use it
      if [ -d "$worktree_path" ]; then
        _wt_msg "Worktree '$wt_name' already exists. Using it."
      else
        _wt_msg "Creating worktree: $wt_name"
        git worktree add "$worktree_path" -b "$wt_name" || {
          _wt_err "Failed to create worktree. You may need to resolve this manually."
          trap - INT
          return 1
        }
      fi

      _wt_msg ""
      _wt_msg "Switching to worktree: $wt_name"
      _wt_msg ""

      trap - INT
      cd "$worktree_path"
      ;;

    ###########################################################################
    # wt delete [name] — remover
    ###########################################################################

    delete)
      # Collect all worktrees under .worktrees (sessions and task worktrees).
      local deletable_worktrees=()
      if [ -d "$worktrees_dir" ]; then
        local wt_dir wt_name
        [ -n "$ZSH_VERSION" ] && setopt local_options NULL_GLOB
        for wt_dir in "$worktrees_dir"/*/; do
          [ -d "$wt_dir" ] || continue
          wt_name="$(basename "$wt_dir")"
          deletable_worktrees+=("$wt_name")
        done
      fi

      if [ ${#deletable_worktrees[@]} -eq 0 ]; then
        _wt_msg "No worktrees found under .worktrees/."
        trap - INT
        return 1
      fi

      local choice="${subarg:-}"

      # No explicit name: prompt interactively.
      if [ -z "$choice" ]; then
        local _tty_available=0
        if [ -t 0 ] || { [ -e /dev/tty ] && : </dev/tty 2>/dev/null; }; then
          _tty_available=1
        fi

        if [ "$_tty_available" -eq 1 ] && command -v fzf >/dev/null 2>&1; then
          local selected
          selected=$(printf '%s\n' "${deletable_worktrees[@]}" | fzf --height=~50% --reverse --prompt="Delete worktree: " --header="Select a worktree to delete, Enter to confirm, Esc to cancel" 2>/dev/null)
          local fzf_exit=$?
          if [ $fzf_exit -ne 0 ] || [ -z "$selected" ]; then
            _wt_msg "No worktree selected."
            trap - INT
            return 1
          fi
          choice="$selected"
        elif [ "$_tty_available" -eq 1 ]; then
          _wt_msg "Existing worktrees:"
          local _i=0
          local _wt
          for _wt in "${deletable_worktrees[@]}"; do
            _i=$((_i + 1))
            _wt_msg "  ${_i}) ${_wt}"
          done
          _wt_msg ""

          local selection
          printf "Select a worktree to delete [1-${#deletable_worktrees[@]}]: " >&2
          read -r selection </dev/tty

          if echo "$selection" | grep -qE '^[0-9]+$' && [ "$selection" -ge 1 ] && [ "$selection" -le ${#deletable_worktrees[@]} ]; then
            _i=0
            for _wt in "${deletable_worktrees[@]}"; do
              _i=$((_i + 1))
              if [ "$_i" -eq "$selection" ]; then
                choice="$_wt"
                break
              fi
            done
          else
            _wt_err "Invalid selection: $selection"
            trap - INT
            return 1
          fi
        else
          _wt_err "No TTY available for interactive delete. Pass a name: wt delete <worktree-name>"
          trap - INT
          return 1
        fi
      fi

      local target_dir="$worktrees_dir/$choice"
      if [ ! -d "$target_dir" ]; then
        _wt_err "Worktree does not exist under .worktrees/: $choice"
        trap - INT
        return 1
      fi

      # Safety: never remove the worktree that contains the current shell cwd.
      local cwd_abs target_abs
      cwd_abs="$(pwd -P)"
      target_abs="$(cd "$target_dir" && pwd -P)"
      case "$cwd_abs" in
        "$target_abs"|"$target_abs"/*)
          _wt_err "Refusing to delete the currently active worktree: $choice"
          trap - INT
          return 1
          ;;
      esac

      # Ask for confirmation unless explicitly forced (WT_DELETE_FORCE=1).
      if [ "${WT_DELETE_FORCE:-0}" != "1" ]; then
        local _confirm=""
        if [ -t 0 ] || { [ -e /dev/tty ] && : </dev/tty 2>/dev/null; }; then
          printf "Delete worktree '%s'? [y/N]: " "$choice" >&2
          read -r _confirm </dev/tty
        else
          _wt_err "No TTY available for confirmation. Re-run with WT_DELETE_FORCE=1."
          trap - INT
          return 1
        fi
        case "$_confirm" in
          y|Y|yes|YES) ;;
          *)
            _wt_msg "Delete cancelled."
            trap - INT
            return 1
            ;;
        esac
      fi

      _wt_msg "Removing worktree: $choice"
      if ! git worktree remove "$target_dir"; then
        _wt_err "Failed to remove worktree '$choice'. If it has local changes, commit/stash first (or remove manually with force if intentional)."
        trap - INT
        return 1
      fi

      # Clean stale worktree metadata if any.
      git worktree prune >/dev/null 2>&1 || true

      # If branch name matches worktree name, try to remove it when merged.
      if git show-ref --verify --quiet "refs/heads/$choice" 2>/dev/null; then
        if git branch -d "$choice" >/dev/null 2>&1; then
          _wt_msg "Deleted local branch: $choice"
        else
          _wt_warn "Kept local branch '$choice' (not fully merged). Remove manually if desired: git branch -D $choice"
        fi
      fi

      _wt_msg "Deleted worktree: $choice"
      trap - INT
      return 0
      ;;

    ###########################################################################
    # wt (no args) — pure selector
    ###########################################################################

    "")
      # Collect existing session worktrees (directories without -- in their name)
      local session_worktrees=()
      if [ -d "$worktrees_dir" ]; then
        local wt_dir wt_name
        # Suppress "no matches found" in zsh when glob matches nothing
        [ -n "$ZSH_VERSION" ] && setopt local_options NULL_GLOB
        for wt_dir in "$worktrees_dir"/*/; do
          [ -d "$wt_dir" ] || continue
          wt_name="$(basename "$wt_dir")"
          # Skip task worktrees (contain --)
          case "$wt_name" in *--*) continue ;; esac
          session_worktrees+=("$wt_name")
        done
      fi

      if [ ${#session_worktrees[@]} -eq 0 ]; then
        _wt_msg "No worktrees found. Use \`wt new\` to create one."
        trap - INT
        return 1
      fi

      # Detect whether a TTY is available for interactive prompts
      local _tty_available=0
      if [ -t 0 ] || { [ -e /dev/tty ] && : </dev/tty 2>/dev/null; }; then
        _tty_available=1
      fi

      local choice=""
      if [ "$_tty_available" -eq 1 ] && command -v fzf >/dev/null 2>&1; then
        # fzf mode: include a delete action plus worktree names.
        local _delete_action="[delete] Delete a worktree..."
        local selected
        selected=$(
          {
            printf '%s\n' "$_delete_action"
            printf '%s\n' "${session_worktrees[@]}"
          } | fzf --height=~50% --reverse --prompt="Select worktree: " --header="Arrow keys to navigate, Enter to select, Esc to cancel" 2>/dev/null
        )
        local fzf_exit=$?
        if [ $fzf_exit -ne 0 ] || [ -z "$selected" ]; then
          _wt_msg "No worktree selected."
          trap - INT
          return 1
        fi
        if [ "$selected" = "$_delete_action" ]; then
          trap - INT
          wt delete
          return $?
        fi
        choice="$selected"
      elif [ "$_tty_available" -eq 1 ]; then
        # Fallback: numbered list (fzf not installed but TTY available)
        _wt_msg "Existing worktrees:"
        local _i=0
        local _wt
        for _wt in "${session_worktrees[@]}"; do
          _i=$((_i + 1))
          _wt_msg "  ${_i}) ${_wt}"
        done
        _wt_msg ""
        _wt_msg "  d) Delete a worktree..."
        _wt_msg ""

        local selection
        printf "Select a worktree [1-${#session_worktrees[@]}, d]: " >&2
        read -r selection </dev/tty

        case "$selection" in
          d|D|delete|DELETE)
            trap - INT
            wt delete
            return $?
            ;;
        esac

        if echo "$selection" | grep -qE '^[0-9]+$' && [ "$selection" -ge 1 ] && [ "$selection" -le ${#session_worktrees[@]} ]; then
          # Portable: walk array to find the Nth element
          _i=0
          for _wt in "${session_worktrees[@]}"; do
            _i=$((_i + 1))
            if [ "$_i" -eq "$selection" ]; then
              choice="$_wt"
              break
            fi
          done
        else
          _wt_err "Invalid selection: $selection"
          trap - INT
          return 1
        fi
      else
        # No TTY available — cannot interactively select
        _wt_err "No TTY available for interactive selection. Run 'wt' in an interactive terminal."
        _wt_msg "Available worktrees:"
        local _i=0
        local _wt
        for _wt in "${session_worktrees[@]}"; do
          _i=$((_i + 1))
          _wt_msg "  ${_i}) ${_wt}"
        done
        trap - INT
        return 1
      fi

      local target_dir="$worktrees_dir/$choice"

      if [ ! -d "$target_dir" ]; then
        _wt_err "Worktree directory does not exist: $target_dir"
        trap - INT
        return 1
      fi

      _wt_msg ""
      _wt_msg "Switching to worktree: $choice"
      _wt_msg ""

      trap - INT
      cd "$target_dir"
      ;;

    ###########################################################################
    # wt <unknown> — usage error
    ###########################################################################

    *)
      _wt_err "Unknown subcommand: $subcmd"
      _wt_msg "Usage: wt [new|delete [name]]"
      trap - INT
      return 1
      ;;

  esac
}

# Launch Claude. Dashboard panes are opened by the SessionStart hook so
# dependency bootstrap runs first and panes are not opened twice.
_claude_launch() {
  command claude "$@"
}

# claude() — Worktree-first shell function for Claude Code.
#
# Prevents Claude Code sessions from accidentally working on the default branch
# (main/master) of a git repo. When it detects that situation, it calls wt()
# to select an existing worktree, falling back to wt new if none exist, then
# launches Claude inside it.
#
# Pass-through cases (no intervention):
#   - Not inside a git repository
#   - Already inside a git worktree
#   - On a non-default branch (not main/master)
#
# Target case (on main/master in a repo root):
#   - Tries wt (selector) first; if that fails because no worktrees exist,
#     falls back to wt new (creator).
#   - Launches claude from inside the chosen worktree (in a subshell so the
#     cd from wt does not leak to the parent shell).
#
# Compatible with bash and zsh.

claude() {
  #############################################################################
  # --skip / -s flag: bypass worktree check and disable multiagent hooks
  #############################################################################

  local _claude_args=()
  local _skip_worktree=0
  for _arg in "$@"; do
    case "$_arg" in
      --skip|-s) _skip_worktree=1 ;;
      *) _claude_args+=("$_arg") ;;
    esac
  done

  if [ "$_skip_worktree" -eq 1 ]; then
    # Disable claude-multiagent for this Claude process and its hooks.
    # This gives an escape hatch for a plain Claude session.
    CLAUDE_MULTIAGENT_DISABLE=1 command claude "${_claude_args[@]}"
    return $?
  fi

  ###########################################################################  
  # Case 1: Not a git repo → pass through
  #############################################################################

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    command claude "$@"
    return $?
  fi

  #############################################################################
  # Case 2: Already in a worktree → pass through
  #############################################################################

  local git_dir git_common_dir abs_git_dir abs_git_common
  git_dir="$(git rev-parse --git-dir 2>/dev/null)"
  git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"

  # Normalize to absolute paths for reliable comparison
  abs_git_dir="$(cd "$git_dir" && pwd)"
  abs_git_common="$(cd "$git_common_dir" && pwd)"

  if [ "$abs_git_dir" != "$abs_git_common" ]; then
    _claude_launch "$@"
    return $?
  fi

  #############################################################################
  # Case 3: On a non-default branch → pass through
  #############################################################################

  local default_branch current_branch
  # Detect the default branch dynamically
  default_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')"
  if [ -z "$default_branch" ]; then
    # Fallback: check if main or master exists
    if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
      default_branch="main"
    elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
      default_branch="master"
    else
      default_branch="main"
    fi
  fi

  current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"

  if [ "$current_branch" != "$default_branch" ]; then
    _claude_launch "$@"
    return $?
  fi

  #############################################################################
  # Case 4: On default branch — use wt (selector), fallback to wt new (creator)
  #############################################################################

  printf '%s\n' "" >&2
  printf '%s\n' "You are on the '$default_branch' branch. Claude should run in a worktree." >&2
  printf '%s\n' "" >&2

  # Try selector first; if it fails (no worktrees or user cancels), offer creation.
  # Do NOT wrap wt in a subshell — a subshell loses both the TTY context required
  # for fzf/read AND the cd that switches into the chosen worktree.
  # Calling wt directly (as a shell function) lets cd propagate to this shell.
  { wt || wt new; } || return 1

  # Verify we actually ended up inside a worktree after wt ran.
  # wt() Cases 2 and 3 return 0 (success) without cd-ing (they signal "nothing to
  # do"), which would cause claude to launch in the original non-worktree directory.
  # Re-checking the worktree condition here ensures the cd took effect.
  local post_git_dir post_git_common_dir abs_post_git_dir abs_post_git_common
  post_git_dir="$(git rev-parse --git-dir 2>/dev/null)"
  post_git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
  abs_post_git_dir="$(cd "$post_git_dir" && pwd)"
  abs_post_git_common="$(cd "$post_git_common_dir" && pwd)"

  if [ "$abs_post_git_dir" = "$abs_post_git_common" ]; then
    printf '%s\n' "ERROR: wt did not switch into a worktree. Aborting claude launch." >&2
    return 1
  fi

  _claude_launch "$@"
}
