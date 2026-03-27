# Portable ZSH functions
# Sourced from claude-plugins/shell-configs/zsh-functions/

_CLAUDE_SCREENSHOTS_DIR="/tmp/claude-screenshots"

alias nv='nvim'
# sp — wrapper for ~/projects/specify CLI
# Clones the repo if missing; periodically pulls updates (once per day).
# In Docker sandboxes, falls back to /usr/local/bin/sp script (set up by
# ensure-plugins.sh from mounted host paths).
sp() {
  local _sp_dir="$HOME/projects/specify"
  local _sp_wrapper="$_sp_dir/specify"
  local _sp_stamp="$_sp_dir/.last-update-check"

  # If the repo dir doesn't exist, try the system-level script (Docker sandbox)
  if [ ! -d "$_sp_dir" ]; then
    if [ -x "/usr/local/bin/sp" ]; then
      command sp "$@"
      return $?
    fi
    if [[ ! -o interactive ]]; then
      printf '\033[1;33m[sp]\033[0m specify not found at %s\n' "$_sp_dir"
      return 1
    fi
    printf '\033[1;33m[sp]\033[0m specify not found at %s\n' "$_sp_dir"
    printf '\033[1;34m[sp]\033[0m Clone from gm2211/specify? [Y/n] '
    read -rsk1 _ans
    printf '\n'
    if [[ "$_ans" == [nN] ]]; then
      printf '\033[1;34m[sp]\033[0m Cancelled.\n'
      return 1
    fi
    git clone https://github.com/gm2211/specify.git "$_sp_dir" || return 1
  fi

  # Periodic update check (at most once per day)
  local _now=$(date +%s)
  local _last=0
  [ -f "$_sp_stamp" ] && _last=$(<"$_sp_stamp")
  if (( _now - _last > 86400 )); then
    printf '\033[90m[sp] checking for updates...\033[0m\n'
    git -C "$_sp_dir" fetch --quiet 2>/dev/null
    local _behind=$(git -C "$_sp_dir" rev-list --count HEAD..@{u} 2>/dev/null)
    if [ -n "$_behind" ] && [ "$_behind" -gt 0 ] 2>/dev/null; then
      printf '\033[1;33m[sp]\033[0m %d commit(s) behind remote. Pulling...\n' "$_behind"
      git -C "$_sp_dir" pull --ff-only --quiet 2>/dev/null
    fi
    printf '%s' "$_now" > "$_sp_stamp"
  fi

  # Use the specify wrapper (auto-builds TypeScript if needed)
  if [ -x "$_sp_wrapper" ]; then
    "$_sp_wrapper" "$@"
    return $?
  fi

  # Fallback: run dist directly
  local _sp_cli="$_sp_dir/dist/src/cli/index.js"
  if [ ! -f "$_sp_cli" ]; then
    printf '\033[1;31m[sp]\033[0m specify not found at %s\n' "$_sp_dir"
    return 1
  fi
  node "$_sp_cli" "$@"
}

# ZLE word-navigation bindings for Kitty + Zellij
# Kitty sends Alt+Left/Right as CSI 1;3D/C; map those to word motion in Zsh.
if [[ -o interactive ]]; then
  bindkey '\e[1;3D' backward-word
  bindkey '\e[1;3C' forward-word
  bindkey '\eb' backward-word
  bindkey '\ef' forward-word
fi


function ss() {
    local dir="${_CLAUDE_SCREENSHOTS_DIR}"
    mkdir -p "$dir"
    local f="${dir}/ss-$(date +%s)-${RANDOM}.png"

    if [[ "$(uname)" == "Darwin" ]] && ! command -v pngpaste &>/dev/null; then
        printf '\033[1;34m[ss]\033[0m Installing pngpaste...\n'
        brew install pngpaste || { echo "Failed to install pngpaste" >&2; return 1; }
    fi

    if command -v pngpaste &>/dev/null; then
        # macOS: grab from pasteboard, copy path to clipboard
        pngpaste "$f" && {
            echo -n "$f" | pbcopy
            echo "Saved & copied: $f"
        }
    elif [ -d "$dir" ] && f="$(find "$dir" -maxdepth 1 -name 'ss-*.png' -print 2>/dev/null | sort -r | head -1)" && [ -n "$f" ]; then
        # Docker/Linux: pick the newest screenshot from the shared mount
        echo "$f"
    else
        echo "No screenshot tool available and no screenshots in $dir" >&2
        echo "Take a screenshot on the host first (ss), then retry here." >&2
        return 1
    fi
}

# wt() — Interactive worktree selector/creator/remover.
#
# Works from any git repo. Dispatches on the first argument:
#
#   wt         — pure selector: lists existing session worktrees, prompts for
#                selection, and cd's into the chosen one.
#   wt new     — creator: offers a date-based session name (session-YYYY-MM-DD)
#                with -N suffix for duplicates. Also accepts custom names.
#                Creates the worktree with `git worktree add` and cd's into it.
#   wt delete  — remover: interactively selects a session worktree and removes
#                it using `git worktree remove` after confirmation.
#                Optional forms: `wt delete <name>`, `wt delete --force`.
#   wt <other> — usage error.
#
# Common behavior (runs before dispatch):
#   - Not inside a git repository → error, return 1
#   - Already inside a git worktree → print which worktree, return 0
#     (except for explicit delete subcommands)
#   - On a non-default branch → print which branch, return 0
#     (except for explicit delete subcommands)
#   - Otherwise dispatch to subcommand
#
# Compatible with bash and zsh.

wt() {
  #############################################################################
  # Helpers
  #############################################################################

  _wt_msg()  { printf '%s\n' "$*" >&2; }
  _wt_warn() { printf 'WARNING: %s\n' "$*" >&2; }
  _wt_err()  { printf 'ERROR: %s\n' "$*" >&2; }

  # Resolve a worktree basename to its absolute path via git worktree list.
  # Prints the path to stdout; returns 1 if not found.
  _wt_resolve_path() {
    local name="$1" _line _path
    while IFS= read -r _line; do
      _path="${_line%%  *}"
      if [ "$(basename "$_path")" = "$name" ]; then
        printf '%s' "$_path"
        return 0
      fi
    done < <(git worktree list 2>/dev/null)
    return 1
  }

  local subcmd="${1:-}"
  local is_delete_cmd=0
  case "$subcmd" in
    delete|rm|remove) is_delete_cmd=1 ;;
  esac

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
  #############################################################################

  local git_dir git_common_dir abs_git_dir abs_git_common
  git_dir="$(git rev-parse --git-dir 2>/dev/null)"
  git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"

  # Normalize to absolute paths for reliable comparison
  abs_git_dir="$(cd "$git_dir" && pwd)"
  abs_git_common="$(cd "$git_common_dir" && pwd)"

  if [ "$abs_git_dir" != "$abs_git_common" ] && [ "$is_delete_cmd" -eq 0 ]; then
    local wt_branch
    wt_branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo "(detached)")"
    _wt_msg "Already in a worktree: $wt_branch ($(pwd))"
    trap - INT
    return 0
  fi

  #############################################################################
  # Case 3: On a non-default branch → inform and return
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

  if [ "$current_branch" != "$default_branch" ] && [ "$is_delete_cmd" -eq 0 ]; then
    _wt_msg "On branch '$current_branch' (not the default branch)."
    trap - INT
    return 0
  fi

  #############################################################################
  # Case 4: Dispatch on subcommand
  #############################################################################

  local repo_root worktrees_dir
  repo_root="$(cd "$abs_git_common/.." && pwd)"
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
    # wt (no args) — pure selector
    ###########################################################################

    "")
      # Collect existing session worktrees from git worktree list (not just .worktrees/)
      local session_worktrees=()
      local _wt_path _wt_name
      while IFS= read -r _wt_line; do
        # git worktree list format: "/path/to/worktree  <hash> [branch]"
        _wt_path="${_wt_line%%  *}"
        # Skip the main repo root itself
        [ "$_wt_path" = "$repo_root" ] && continue
        _wt_name="$(basename "$_wt_path")"
        # Skip task worktrees (contain --)
        case "$_wt_name" in *--*) continue ;; esac
        session_worktrees+=("$_wt_name")
      done < <(git worktree list 2>/dev/null)

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
        # fzf mode: pipe worktree names, let user arrow-select
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

      local target_dir
      target_dir="$(_wt_resolve_path "$choice")" || {
        _wt_err "Worktree directory not found for '$choice'."
        trap - INT
        return 1
      }

      _wt_msg ""
      _wt_msg "Switching to worktree: $choice"
      _wt_msg ""

      trap - INT
      cd "$target_dir"
      ;;

    ###########################################################################
    # wt delete / rm / remove — remover
    ###########################################################################

    delete|rm|remove)
      local del_force=0
      local del_name=""
      local arg

      shift
      for arg in "$@"; do
        case "$arg" in
          -f|--force) del_force=1 ;;
          *)
            if [ -z "$del_name" ]; then
              del_name="$arg"
            else
              _wt_err "Too many arguments for delete."
              _wt_msg "Usage: wt delete [name] [--force]"
              trap - INT
              return 1
            fi
            ;;
        esac
      done

      # Collect existing session worktrees from git worktree list (not just .worktrees/)
      local session_worktrees=()
      local _wt_line _wt_path _wt_name
      while IFS= read -r _wt_line; do
        _wt_path="${_wt_line%%  *}"
        [ "$_wt_path" = "$repo_root" ] && continue
        _wt_name="$(basename "$_wt_path")"
        case "$_wt_name" in *--*) continue ;; esac
        session_worktrees+=("$_wt_name")
      done < <(git worktree list 2>/dev/null)

      if [ ${#session_worktrees[@]} -eq 0 ]; then
        _wt_msg "No worktrees found to delete."
        trap - INT
        return 1
      fi

      local choice=""
      if [ -n "$del_name" ]; then
        local found=0
        local _wt
        for _wt in "${session_worktrees[@]}"; do
          if [ "$_wt" = "$del_name" ]; then
            found=1
            break
          fi
        done
        if [ "$found" -eq 0 ]; then
          _wt_err "Worktree '$del_name' was not found."
          _wt_msg "Available worktrees:"
          local _i=0
          for _wt in "${session_worktrees[@]}"; do
            _i=$((_i + 1))
            _wt_msg "  ${_i}) ${_wt}"
          done
          trap - INT
          return 1
        fi
        choice="$del_name"
      else
        # Detect whether a TTY is available for interactive prompts
        local _tty_available=0
        if [ -t 0 ] || { [ -e /dev/tty ] && : </dev/tty 2>/dev/null; }; then
          _tty_available=1
        fi

        if [ "$_tty_available" -eq 1 ] && command -v fzf >/dev/null 2>&1; then
          local selected
          selected=$(printf '%s\n' "${session_worktrees[@]}" | fzf --height=~50% --reverse --prompt="Delete worktree: " --header="Arrow keys to navigate, Enter to select, Esc to cancel" 2>/dev/null)
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
          for _wt in "${session_worktrees[@]}"; do
            _i=$((_i + 1))
            _wt_msg "  ${_i}) ${_wt}"
          done
          _wt_msg ""

          local selection
          printf "Select a worktree to delete [1-${#session_worktrees[@]}]: " >&2
          read -r selection </dev/tty

          if echo "$selection" | grep -qE '^[0-9]+$' && [ "$selection" -ge 1 ] && [ "$selection" -le ${#session_worktrees[@]} ]; then
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
          _wt_err "No TTY available for interactive deletion. Use: wt delete <name> [--force]"
          trap - INT
          return 1
        fi
      fi

      local target_dir
      target_dir="$(_wt_resolve_path "$choice")" || {
        _wt_err "Worktree directory not found for '$choice'."
        trap - INT
        return 1
      }

      local target_abs pwd_abs
      target_abs="$(cd "$target_dir" && pwd -P)"
      pwd_abs="$(pwd -P)"
      case "$pwd_abs/" in
        "$target_abs"/*)
          _wt_err "Cannot delete the current worktree from inside it. Switch directories and retry."
          trap - INT
          return 1
          ;;
      esac

      # Confirm deletion unless --force is provided
      if [ "$del_force" -eq 0 ]; then
        local _tty_available=0
        if [ -t 0 ] || { [ -e /dev/tty ] && : </dev/tty 2>/dev/null; }; then
          _tty_available=1
        fi

        if [ "$_tty_available" -eq 1 ]; then
          local confirm
          printf "Delete worktree '%s'? [y/N]: " "$choice" >&2
          read -r confirm </dev/tty
          case "$confirm" in
            y|Y|yes|YES|Yes) ;;
            *)
              _wt_msg "Deletion cancelled."
              trap - INT
              return 1
              ;;
          esac
        else
          _wt_err "No TTY available for confirmation. Re-run with --force."
          trap - INT
          return 1
        fi
      fi

      local remove_args=()
      [ "$del_force" -eq 1 ] && remove_args+=(--force)

      git worktree remove "${remove_args[@]}" "$target_dir" 2>/dev/null || {
        if [ "$del_force" -eq 0 ]; then
          printf "%s" "Worktree has modified/untracked files. Force delete? [y/N]: "
          if [ -t 0 ]; then
            read -r force_confirm
          else
            _wt_err "No TTY for force confirmation. Re-run with --force."
            trap - INT
            return 1
          fi
          if [[ "$force_confirm" =~ ^[Yy]$ ]]; then
            git worktree remove --force "$target_dir" || {
              _wt_err "Failed to force-remove worktree '$choice'."
              trap - INT
              return 1
            }
          else
            _wt_msg "Kept worktree '$choice'."
            trap - INT
            return 0
          fi
        else
          _wt_err "Failed to remove worktree '$choice' (even with --force)."
          trap - INT
          return 1
        fi
      }

      git worktree prune >/dev/null 2>&1
      _wt_msg "Removed worktree: $choice"
      trap - INT
      ;;

    ###########################################################################
    # wt <unknown> — usage error
    ###########################################################################

    *)
      _wt_err "Unknown subcommand: $subcmd"
      _wt_msg "Usage: wt [new|delete [name] [--force]]"
      trap - INT
      return 1
      ;;

  esac
}

# f() — Friendlier find.
#
# Addresses the main find annoyances: no -name/-iname flag needed (first arg
# is the pattern), case-insensitive by default, auto-wraps bare words in
# wildcards, and -x replaces the -exec {} \; dance.
#
#   f pattern [dir] [options]
#
# Options:
#   -t TYPE    File type: f(ile), d(ir), l(ink)
#   -x CMD     Execute CMD on each match ({} = match path, auto-appended if missing)
#   -n DAYS    Modified within last DAYS days
#   -d DEPTH   Max directory depth
#   -s         Case-sensitive (default: case-insensitive)
#   -1         Stop after first match
#   --delete   Delete matching files
#   -- CMD     Execute CMD on each match ({} auto-appended if missing)
#
# Examples:
#   f "*.js"                Find all .js files
#   f config -t d           Find directories containing "config"
#   f "*.ttf" -- cat        Exec cat on each match (cat {} \;)
#   f "*.log" -- rm         Delete .log files
#   f todo /src -n 7        Files with "todo" modified in last 7 days
#   f "*.pyc" --delete      Delete all .pyc files
#   f readme -1             First file matching *readme*

f() {
  # ---------------------------------------------------------------------------
  # Help
  # ---------------------------------------------------------------------------
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat <<'EOF'
f — friendlier find

Usage: f <pattern> [dir] [options]    (direct mode)
       f                               (interactive mode)

  pattern             Glob or substring (auto-wrapped in *…* if no wildcards)
  dir                 Directory to search (default: .)

Options:
  -t TYPE    Type: f(ile), d(ir), l(ink)
  -x CMD     Execute CMD on each match ({} auto-appended if missing)
  -n DAYS    Modified within last DAYS days
  -d DEPTH   Max depth
  -s         Case-sensitive (default: insensitive)
  -1         First result only
  -v         Show permission-denied paths (normally just a count)
  --delete   Delete matching files
  -- CMD     Execute CMD on each match (same as -x, but at end of line)

Examples:
  f "*.js"                Find all .js files
  f config -t d           Directories containing "config"
  f "*.ttf" -- cat        Cat every .ttf file
  f "*.log" -- rm         Delete .log files
  f todo /src -n 7        "todo" files modified in last 7 days
  f "*.pyc" --delete      Delete all .pyc files
  f readme -1             First file matching *readme*
EOF
    return 0
  fi

  # ---------------------------------------------------------------------------
  # Interactive mode (no args)
  # ---------------------------------------------------------------------------
  if [[ $# -eq 0 ]]; then
    local _dir _pattern _exec_cmd _batch _ans

    printf 'Directory to search [.]: ' >&2
    read -r _dir </dev/tty
    [[ -z "$_dir" ]] && _dir="."

    printf 'File name pattern: ' >&2
    read -r _pattern </dev/tty
    if [[ -z "$_pattern" ]]; then
      printf 'f: pattern cannot be empty\n' >&2
      return 1
    fi

    printf 'Command to run (leave blank to just list; use {} for match path): ' >&2
    read -r _exec_cmd </dev/tty

    if [[ -n "$_exec_cmd" ]]; then
      printf 'Run once per file, or batch all into one invocation?\n' >&2
      printf '  1) Each file separately   (e.g. rm file1; rm file2; …)\n' >&2
      printf '  2) All at once            (e.g. rm file1 file2 …)\n' >&2
      printf 'Choice [1]: ' >&2
      read -r _ans </dev/tty
      [[ "$_ans" == "2" ]] && _batch=1 || _batch=0

      # Build and run via direct mode
      local -a _args=("$_pattern" "$_dir")
      if (( _batch )); then
        _args+=(-x+ "$_exec_cmd")
      else
        _args+=(-x "$_exec_cmd")
      fi
      f "${_args[@]}"
    else
      f "$_pattern" "$_dir"
    fi
    return
  fi

  # ---------------------------------------------------------------------------
  # Direct mode — parse args
  # ---------------------------------------------------------------------------
  local pattern="" dir="." type_flag="" exec_cmd="" newer=""
  local case_sensitive=0 delete=0 first_only=0 maxdepth="" batch=0 verbose_errors=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t) type_flag="$2"; shift 2 ;;
      -x) exec_cmd="$2"; shift 2 ;;
      -x+) exec_cmd="$2"; batch=1; shift 2 ;;
      -n) newer="$2"; shift 2 ;;
      -d) maxdepth="$2"; shift 2 ;;
      -s) case_sensitive=1; shift ;;
      -1) first_only=1; shift ;;
      -v) verbose_errors=1; shift ;;
      --delete) delete=1; shift ;;
      --) shift; exec_cmd="$*"; break ;;
      -*)
        printf 'f: unknown option: %s\n' "$1" >&2
        return 1
        ;;
      *)
        if [[ -z "$pattern" ]]; then
          pattern="$1"
        elif [[ -d "$1" ]]; then
          dir="$1"
        else
          dir="$1"
        fi
        shift
        ;;
    esac
  done

  # Auto-wrap bare words in wildcards
  if [[ -n "$pattern" && "$pattern" != *'*'* && "$pattern" != *'?'* && "$pattern" != *'['* ]]; then
    pattern="*${pattern}*"
  fi

  local -a cmd=(find "$dir")

  [[ -n "$maxdepth" ]] && cmd+=(-maxdepth "$maxdepth")
  [[ -n "$type_flag" ]] && cmd+=(-type "$type_flag")

  if [[ -n "$pattern" ]]; then
    if (( case_sensitive )); then
      cmd+=(-name "$pattern")
    else
      cmd+=(-iname "$pattern")
    fi
  fi

  [[ -n "$newer" ]] && cmd+=(-mtime "-${newer}")

  if (( delete )); then
    cmd+=(-delete -print)
  elif [[ -n "$exec_cmd" ]]; then
    # Auto-append {} if the user left it out
    [[ "$exec_cmd" != *'{}'* ]] && exec_cmd="${exec_cmd} {}"
    cmd+=(-exec ${=exec_cmd})
    if (( batch )); then
      cmd+=(+)
    else
      cmd+=(\;)
    fi
  fi

  (( first_only )) && cmd+=(-print -quit)

  # Run find, capture stderr to summarize permission errors
  local _err_file="${TMPDIR:-/tmp}/f-err-$$.tmp"
  local _exit=0

  if [[ -t 1 ]]; then
    # Interactive TTY: show live spinner + match count
    local _count=0 _spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') _si=0
    while IFS= read -r _line; do
      _count=$((_count + 1))
      printf '\033[2K\r%s\n' "$_line"
      printf '\r\033[90m%s %d found…\033[0m' "${_spin[$(( _si % 10 + 1 ))]}" "$_count" >&2
      _si=$((_si + 1))
    done < <("${cmd[@]}" 2>"$_err_file"; echo "__F_EXIT_$?" >&2)
    # Clear spinner line
    printf '\033[2K\r' >&2
    # Extract exit code from the sentinel we appended to stderr
    _exit=$(grep -o '__F_EXIT_[0-9]*' "$_err_file" 2>/dev/null | head -1 | sed 's/__F_EXIT_//')
    _exit=${_exit:-0}
    # Remove the sentinel from the error file
    sed -i '' '/__F_EXIT_/d' "$_err_file" 2>/dev/null
  else
    # Piped: no decoration
    "${cmd[@]}" 2>"$_err_file"
    _exit=$?
  fi

  local _perm_count=0 _other_errs=""
  if [[ -s "$_err_file" ]]; then
    _perm_count=$(grep -c 'Permission denied\|Operation not permitted' "$_err_file" 2>/dev/null || echo 0)
    _other_errs=$(grep -v 'Permission denied\|Operation not permitted' "$_err_file" 2>/dev/null || true)

    # Print non-permission errors normally
    [[ -n "$_other_errs" ]] && printf '%s\n' "$_other_errs" >&2

    if (( _perm_count > 0 )); then
      printf '\033[90m(%d paths not searchable — permission denied' "$_perm_count" >&2
      if (( verbose_errors )); then
        printf ':\033[0m\n' >&2
        grep 'Permission denied\|Operation not permitted' "$_err_file" \
          | sed 's/^find: /  /' | sed 's/: [A-Z].*$//' >&2
      else
        printf '; use -v to list)\033[0m\n' >&2
      fi
    fi
  fi

  rm -f "$_err_file"
  return $_exit
}

# Locate a script inside the claude-multiagent plugin directory.
# Searches the marketplace install path (stable across versions).
_find_multiagent_script() {
  local name="$1" match
  for match in ~/.claude/plugins/marketplaces/*/plugins/claude-multiagent/scripts/"$name"; do
    [[ -x "$match" ]] && echo "$match" && return 0
  done
  return 1
}


# Open dashboard panes (if available) then launch claude.
# Pane script is idempotent — safe to call on every launch.
_claude_launch() {
  if [[ "${CLAUDE_MULTIAGENT_DISABLE:-}" != "1" ]]; then
    local _ds
    _ds="$(_find_multiagent_script "open-dashboard.sh" 2>/dev/null)" || true
    if [[ -n "$_ds" ]]; then
      "$_ds" "$PWD" &>/dev/null &
      disown 2>/dev/null
    fi
  fi
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

cl() {
  #############################################################################
  # --skip / -s flag: bypass worktree check and disable multiagent plugin
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
    CLAUDE_MULTIAGENT_DISABLE=1 _claude_launch "${_claude_args[@]}"
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

# clauded() — Launch Claude inside a Docker sandbox with custom dev environment.
# Uses gm-claude-dev template (zellij, nvim, starship, zsh).
# Auto-builds the image on first use. Use --rebuild to force a fresh build.
clauded() {
  local _image="gm-claude-dev"
  local _repo="$HOME/projects/claude-plugins"
  local _dockerfile="docker/Dockerfile"
  local _rebuild=false
  local _no_cache=false
  local _mount=false
  local _extra_mounts=()
  local _env_vars=()
  local _forward_ports=()

  # Parse flags
  while [[ "$1" == --* || "$1" == -* ]]; do
    case "$1" in
      --rebuild)  _rebuild=true; shift ;;
      --no-cache) _no_cache=true; _rebuild=true; shift ;;
      --mount|-m) _mount=true; shift ;;
      -e)         shift; _env_vars+=("$1"); shift ;;
      -p)         shift; _forward_ports+=("$1"); shift ;;
      *) break ;;
    esac
  done

  # Compute content hash of Dockerfile + all COPY'd source directories
  _clauded_content_hash() {
    (
      cd "$_repo" || return 1
      cat "$_dockerfile"
      find shell-configs/zellij shell-configs/nvim \
           shell-configs/zsh-functions shell-configs/claude-status-line \
           -type f 2>/dev/null | sort | xargs cat 2>/dev/null
    ) | shasum -a 256 | cut -d' ' -f1
  }

  local _hash_file="$HOME/.cache/clauded/image-hash"
  local _current_hash
  _current_hash=$(_clauded_content_hash)

  # Build image if needed (track whether we rebuilt so we can remove stale sandboxes)
  local _did_rebuild=false
  local _build_flags=()
  $_no_cache && _build_flags+=(--no-cache)

  if $_rebuild; then
    printf '\033[1;34m[clauded]\033[0m Rebuilding %s...\n' "$_image"
    docker build "${_build_flags[@]}" -t "$_image" -f "$_repo/$_dockerfile" "$_repo" || return 1
    _did_rebuild=true
  elif ! docker image inspect "$_image" &>/dev/null; then
    printf '\033[1;34m[clauded]\033[0m Image %s not found, building...\n' "$_image"
    docker build "${_build_flags[@]}" -t "$_image" -f "$_repo/$_dockerfile" "$_repo" || return 1
    _did_rebuild=true
  elif [ ! -f "$_hash_file" ] || [ "$_current_hash" != "$(cat "$_hash_file")" ]; then
    printf '\033[1;33m[clauded]\033[0m Dockerfile or configs changed since last build. Rebuild? [Y/n] '
    read -rsk1 _ans
    printf '\n'
    if [[ "$_ans" != [nN] ]]; then
      printf '\033[1;34m[clauded]\033[0m Rebuilding %s...\n' "$_image"
      docker build "${_build_flags[@]}" -t "$_image" -f "$_repo/$_dockerfile" "$_repo" || return 1
      _did_rebuild=true
    fi
  fi

  # Auto-inject DigitalOcean API token if not already provided.
  # Sources from: doctl config, then macOS keychain, then skips.
  local _has_do=false
  for _ev in "${_env_vars[@]}"; do
    [[ "$_ev" == DIGITALOCEAN_API_TOKEN=* ]] && _has_do=true
  done
  if ! $_has_do; then
    local _do_token=""
    # Try doctl config first
    if command -v doctl &>/dev/null; then
      _do_token=$(doctl auth list --format Token --no-header 2>/dev/null | head -1)
    fi
    # Fallback: extract from doctl config.yaml
    if [ -z "$_do_token" ]; then
      local _doctl_config="$HOME/Library/Application Support/doctl/config.yaml"
      [ -f "$_doctl_config" ] && _do_token=$(grep '^access-token:' "$_doctl_config" | awk '{print $2}')
    fi
    if [ -n "$_do_token" ]; then
      _env_vars+=("DIGITALOCEAN_API_TOKEN=$_do_token")
      printf '\033[1;32m[clauded]\033[0m DigitalOcean token loaded from doctl.\n'
    fi
  fi

  # Keep specify up to date (once per day, same logic as the sp function)
  if [ -d "$HOME/projects/specify/.git" ]; then
    local _sp_stamp="$HOME/projects/specify/.last-update-check"
    local _now=$(date +%s)
    local _last=0
    [ -f "$_sp_stamp" ] && _last=$(<"$_sp_stamp")
    if (( _now - _last > 86400 )); then
      printf '\033[90m[clauded] checking specify for updates...\033[0m\n'
      git -C "$HOME/projects/specify" fetch --quiet 2>/dev/null
      local _behind=$(git -C "$HOME/projects/specify" rev-list --count HEAD..@{u} 2>/dev/null)
      if [ -n "$_behind" ] && [ "$_behind" -gt 0 ] 2>/dev/null; then
        printf '\033[1;33m[clauded]\033[0m specify is %d commit(s) behind. Pulling...\n' "$_behind"
        git -C "$HOME/projects/specify" pull --ff-only --quiet 2>/dev/null
      fi
      printf '%s' "$_now" > "$_sp_stamp"
    fi
  fi

  # Ensure Dolt is running on the host so the sandbox can forward to it.
  # Looks for .beads/ in the current workspace; starts dolt sql-server if needed.
  local _beads_dir=""
  local _beads_candidates=(.beads(N) */.beads(N))
  for _bd in "${_beads_candidates[@]}"; do
    [ -d "$_bd/dolt" ] && _beads_dir="$_bd" && break
  done
  if [ -n "$_beads_dir" ]; then
    local _dolt_port=""
    local _dolt_pid=""
    # Check if dolt is already running via pid file
    if [ -f "$_beads_dir/dolt-server.pid" ]; then
      _dolt_pid=$(<"$_beads_dir/dolt-server.pid")
      if kill -0 "$_dolt_pid" 2>/dev/null; then
        _dolt_port=$(<"$_beads_dir/dolt-server.port" 2>/dev/null)
      fi
    fi
    # If PID file says not running, check if port is held by a stale process
    if [ -z "$_dolt_port" ]; then
      local _port_pid=""
      _port_pid=$(lsof -ti :3307 2>/dev/null | head -1)
      if [ -n "$_port_pid" ]; then
        local _port_cmd=""
        _port_cmd=$(ps -p "$_port_pid" -o comm= 2>/dev/null)
        if [[ "$_port_cmd" == *dolt* ]]; then
          printf '\033[90m[clauded] Reusing existing Dolt process (pid %s) on port 3307.\033[0m\n' "$_port_pid"
          _dolt_port=3307
          _dolt_pid="$_port_pid"
          echo "$_dolt_pid" > "$_beads_dir/dolt-server.pid"
          echo "$_dolt_port" > "$_beads_dir/dolt-server.port"
        else
          printf '\033[1;33m[clauded]\033[0m Port 3307 in use by %s (pid %s).\n' "$_port_cmd" "$_port_pid"
          if [ -f "$_beads_dir/dolt-server.log" ]; then
            printf '\033[90m[clauded] Last log: %s\033[0m\n' "$(tail -1 "$_beads_dir/dolt-server.log")"
          fi
          printf '\033[1;34m[clauded]\033[0m Kill it and start Dolt? [Y/n] '
          read -rsk1 _ans
          printf '\n'
          if [[ "$_ans" != [nN] ]]; then
            kill "$_port_pid" 2>/dev/null
            sleep 1
            kill -0 "$_port_pid" 2>/dev/null && kill -9 "$_port_pid" 2>/dev/null
            # Wait for port to be released
            local _wait=0
            while lsof -ti :3307 &>/dev/null && (( _wait < 5 )); do
              sleep 1
              (( _wait++ ))
            done
            if lsof -ti :3307 &>/dev/null; then
              printf '\033[1;31m[clauded]\033[0m Port 3307 still in use after kill. Skipping Dolt.\n'
              _dolt_port="skip"
            fi
          else
            printf '\033[90m[clauded] Skipping Dolt.\033[0m\n'
            _dolt_port="skip"
          fi
        fi
      fi
    fi
    # Start dolt if still no server running
    if [ -z "$_dolt_port" ]; then
      _dolt_port=3307
      printf '\033[1;34m[clauded]\033[0m Starting Dolt server on port %s...\n' "$_dolt_port"
      nohup dolt sql-server --host 127.0.0.1 --port "$_dolt_port" \
        --data-dir "$_beads_dir/dolt" > "$_beads_dir/dolt-server.log" 2>&1 &
      _dolt_pid=$!
      echo "$_dolt_pid" > "$_beads_dir/dolt-server.pid"
      echo "$_dolt_port" > "$_beads_dir/dolt-server.port"
      sleep 1
      if kill -0 "$_dolt_pid" 2>/dev/null; then
        printf '\033[1;32m[clauded]\033[0m Dolt server started (pid %s, port %s).\n' "$_dolt_pid" "$_dolt_port"
      else
        printf '\033[1;31m[clauded]\033[0m Dolt server failed to start.\n'
        if [ -f "$_beads_dir/dolt-server.log" ]; then
          printf '\033[90m[clauded] Log:\033[0m\n'
          tail -5 "$_beads_dir/dolt-server.log" | while IFS= read -r _line; do
            printf '\033[90m  %s\033[0m\n' "$_line"
          done
        fi
        _dolt_port=""
      fi
    else
      printf '\033[90m[clauded] Dolt already running (pid %s, port %s)\033[0m\n' "$_dolt_pid" "$_dolt_port"
    fi
    if [ -n "$_dolt_port" ] && [ "$_dolt_port" != "skip" ]; then
      _forward_ports+=("$_dolt_port")
    fi
  fi

  # Collect all ports to forward into the sandbox via socat
  if [ ${#_forward_ports[@]} -gt 0 ]; then
    # Deduplicate
    local _unique_ports=($(printf '%s\n' "${_forward_ports[@]}" | sort -un))
    _env_vars+=("SANDBOX_FORWARD_PORTS=${(j:,:)_unique_ports}")
  fi

  # Auto-inject OAuth token — always refresh .credentials.json for the sandbox.
  local _has_oauth=false
  for _ev in "${_env_vars[@]}"; do
    [[ "$_ev" == CLAUDE_CODE_OAUTH_TOKEN=* ]] && _has_oauth=true
  done
  if ! $_has_oauth; then
    local _token_file="$HOME/.claude/.sandbox-token"
    local _token=""
    if [ -f "$_token_file" ]; then
      _token=$(<"$_token_file")
    fi
    if [ -z "$_token" ]; then
      printf '\033[1;33m[clauded]\033[0m No sandbox token found.\n'
      printf '\033[1;34m[clauded]\033[0m Run \033[1mclaude setup-token\033[0m now? (opens browser, token valid for 1 year) [Y/n] '
      read -rsk1 _ans
      printf '\n'
      if [[ "$_ans" != [nN] ]]; then
        printf '\033[1;34m[clauded]\033[0m Starting token setup — follow the browser prompt...\n'
        local _setup_log
        _setup_log="$(mktemp -t clauded-setup.XXXXXX)"
        claude setup-token 2>&1 | tee "$_setup_log"
        _token=$(grep -oE 'sk-ant-[A-Za-z0-9_-]+' "$_setup_log" | head -1)
        rm -f "$_setup_log"
        if [ -z "$_token" ]; then
          printf '\033[1;33m[clauded]\033[0m Could not auto-capture the token.\n'
          printf '\033[1;34m[clauded]\033[0m Paste your token (sk-ant-...): '
          read -r _token
        fi
        if [ -n "$_token" ]; then
          printf '%s' "$_token" > "$_token_file"
          chmod 600 "$_token_file"
          printf '\033[1;32m[clauded]\033[0m Token saved to %s\n' "$_token_file"
        fi
      fi
    fi
    if [ -n "$_token" ]; then
      _env_vars+=("CLAUDE_CODE_OAUTH_TOKEN=$_token")
      # Always refresh .credentials.json so the sandbox gets a valid token
      local _creds_file="$HOME/.claude/.credentials.json"
      local _expires_at=$(( $(date +%s) * 1000 + 31536000000 ))  # +1 year in ms
      printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"","expiresAt":%s,"scopes":["user:inference","user:profile"]}}\n' \
        "$_token" "$_expires_at" > "$_creds_file"
      chmod 600 "$_creds_file"
      printf '\033[1;32m[clauded]\033[0m Sandbox auth token refreshed.\n'
    else
      printf '\033[1;33m[clauded]\033[0m No token — you may need to authenticate inside the sandbox.\n'
    fi
  fi

  # Save current hash after build (or if no build was needed)
  mkdir -p "$(dirname "$_hash_file")"
  printf '%s\n' "$_current_hash" > "$_hash_file"

  unfunction _clauded_content_hash 2>/dev/null

  # ---------------------------------------------------------------------------
  # Extract Claude credentials from macOS Keychain into ~/.claude/.credentials.json
  # so the sandbox can pick them up via the mounted ~/.claude dir.
  # ---------------------------------------------------------------------------
  local _creds_file="$HOME/.claude/.credentials.json"
  local _creds_tmp
  _creds_tmp=$(security find-generic-password \
       -s "Claude Code-credentials" \
       -a "$(whoami)" \
       -w 2>/dev/null)
  if [ -n "$_creds_tmp" ]; then
    printf '%s\n' "$_creds_tmp" > "$_creds_file"
    chmod 600 "$_creds_file"
  elif [ ! -f "$_creds_file" ]; then
    printf '\033[1;33m[clauded]\033[0m Warning: no Claude credentials found in Keychain or %s\n' "$_creds_file"
  fi

  # Write env vars to a temp file for --env-file; cleaned up on exit
  local _env_file=""
  if [ ${#_env_vars[@]} -gt 0 ]; then
    _env_file="$(mktemp -t clauded-env.XXXXXX)"
    for _ev in "${_env_vars[@]}"; do
      printf '%s\n' "$_ev"
    done > "$_env_file"
    chmod 600 "$_env_file"
  fi

  _clauded_cleanup() { [ -n "$_env_file" ] && rm -f "$_env_file" 2>/dev/null; }
  trap '_clauded_cleanup' EXIT INT TERM

  # -------------------------------------------------------------------------
  # Extra mount picker — fzf-based directory browser with multiselect.
  # Called only when creating a new sandbox (mounts can't be added later).
  # -------------------------------------------------------------------------
  _clauded_prompt_mounts() {
    if ! $_mount; then
      printf '\033[1;34m[clauded]\033[0m Mount extra directories into sandbox? [y/N] '
      read -rsk1 _ans
      printf '\n'
      [[ "$_ans" == [yY] ]] && _mount=true
    fi

    if $_mount; then
      if command -v fzf >/dev/null 2>&1; then
        printf '\033[90m  Tab=toggle  Enter=confirm  Esc=skip\033[0m\n'
        local _selected
        local _search_roots=()
        for _r in "$HOME/projects" "$HOME/src" "$HOME/work" "$HOME/repos"; do
          [ -d "$_r" ] && _search_roots+=("$_r")
        done
        [ ${#_search_roots[@]} -eq 0 ] && _search_roots=("$HOME")
        _selected=$(
          find "${_search_roots[@]}" -maxdepth 3 -type d \
            -not -path '*/\.*' \
            -not -path '*/node_modules/*' \
            -not -path '*/venv/*' \
            -not -path '*/.venv/*' \
            -not -path '*/__pycache__/*' \
            -not -path '*/target/*' \
            -not -path '*/build/*' \
            -not -path '*/.worktrees/*' \
            2>/dev/null \
          | sed "s|^$HOME|~|" \
          | sort \
          | fzf --multi \
                --height=~60% \
                --reverse \
                --prompt="Select directories to mount (ro): " \
                --header="Tab=toggle  Enter=confirm  Esc=skip" \
                --bind="enter:select+accept" \
                --preview="ls -lhF --color=always \$(echo {} | sed \"s|^~|$HOME|\")" \
                --preview-window=right:40% \
            2>/dev/null
        )
        if [ -n "$_selected" ]; then
          while IFS= read -r _dir; do
            _dir="${_dir/#\~/$HOME}"
            _extra_mounts+=("${_dir}:ro")
            printf '\033[1;34m[clauded]\033[0m  + %s (ro)\n' "$_dir"
          done <<< "$_selected"
        fi
      else
        printf '\033[1;33m[clauded]\033[0m fzf not found — install with: brew install fzf\n'
      fi
    fi
  }

  # -------------------------------------------------------------------------
  # Build workspace list for sandbox creation
  # -------------------------------------------------------------------------
  _clauded_build_workspaces() {
    local _pwd_real
    _pwd_real="$(pwd -P)"
    _workspaces=(".")

    _clauded_add_mount() {
      local _path="${1%%:*}"
      local _real
      _real="$(cd "$_path" 2>/dev/null && pwd -P)" || return 0
      [ "$_real" = "$_pwd_real" ] && return 0
      [[ "$_pwd_real" == "$_real"/* ]] && return 0
      _workspaces+=("$1")
    }

    [ -d "$HOME/.claude" ] && _clauded_add_mount "$HOME/.claude"
    [ -d "$HOME/.codex" ] && _clauded_add_mount "$HOME/.codex:ro"
    [ -d "$HOME/.config/gh" ] && _clauded_add_mount "$HOME/.config/gh:ro"
    [ -d "$HOME/projects/specify" ] && _clauded_add_mount "$HOME/projects/specify:ro"
    mkdir -p "${_CLAUDE_SCREENSHOTS_DIR}"
    _clauded_add_mount "${_CLAUDE_SCREENSHOTS_DIR}:ro"
    for _m in "${_extra_mounts[@]}"; do
      _clauded_add_mount "$_m"
    done
    unfunction _clauded_add_mount 2>/dev/null
  }

  # -------------------------------------------------------------------------
  # Apply .sandbox-network rules to a sandbox
  # -------------------------------------------------------------------------
  _clauded_apply_network() {
    local _sandbox_name="$1"
    local _pwd_real
    _pwd_real="$(pwd -P)"

    local _allow_hosts=() _bypass_hosts=()
    for _ws in "${_workspaces[@]}"; do
      local _ws_dir="${_ws%%:*}"
      [ "$_ws_dir" = "." ] && _ws_dir="$_pwd_real"
      if [ -f "$_ws_dir/.sandbox-network" ]; then
        while IFS= read -r _line; do
          _line="${_line%%#*}"
          _line="${_line// /}"
          [ -z "$_line" ] && continue
          if [[ "$_line" == bypass:* ]]; then
            _bypass_hosts+=("${_line#bypass:}")
          elif [[ "$_line" == allow:* ]]; then
            _allow_hosts+=("${_line#allow:}")
          else
            _allow_hosts+=("$_line")
          fi
        done < "$_ws_dir/.sandbox-network"
      fi
    done

    if [ ${#_allow_hosts[@]} -gt 0 ] || [ ${#_bypass_hosts[@]} -gt 0 ]; then
      local _proxy_args=(docker sandbox network proxy "$_sandbox_name")
      for _h in "${_allow_hosts[@]}"; do _proxy_args+=(--allow-host "$_h"); done
      for _h in "${_bypass_hosts[@]}"; do _proxy_args+=(--bypass-host "$_h"); done
      printf '\033[90m[clauded] Network rules:'
      [ ${#_allow_hosts[@]} -gt 0 ] && printf ' allow=%s' "${_allow_hosts[*]}"
      [ ${#_bypass_hosts[@]} -gt 0 ] && printf ' bypass=%s' "${_bypass_hosts[*]}"
      printf '\033[0m\n'
      (
        for _try in 1 2 3 4 5; do
          sleep 1
          "${_proxy_args[@]}" 2>/dev/null && break
        done
      ) &!
    fi
  }

  # -------------------------------------------------------------------------
  # Create a new sandbox: create → init → apply network → attach
  # -------------------------------------------------------------------------
  _clauded_create_and_attach() {
    local _sandbox_name="claude-$(basename "$(pwd -P)")"
    local _workspaces=()
    _clauded_build_workspaces

    printf '\033[90m[clauded] Creating sandbox %s...\033[0m\n' "$_sandbox_name"
    local _create_cmd=(docker sandbox create -t "$_image" --name "$_sandbox_name" claude "${_workspaces[@]}")
    printf '\033[90m[clauded] %s\033[0m\n' "${_create_cmd[*]}"
    "${_create_cmd[@]}" || return 1

    # One-shot init: run ensure-plugins.sh with env vars
    local _init_args=(docker sandbox exec)
    [ -n "$_env_file" ] && _init_args+=(--env-file "$_env_file")
    _init_args+=("$_sandbox_name" /home/agent/.local/bin/ensure-plugins.sh)
    printf '\033[90m[clauded] Running init...\033[0m\n'
    "${_init_args[@]}" 2>&1

    # Apply network rules
    _clauded_apply_network "$_sandbox_name"

    # Attach via exec — zsh will auto-start zellij
    _clauded_attach "$_sandbox_name" "$@"
  }

  # -------------------------------------------------------------------------
  # Attach to a sandbox: exec -it with env vars, workspace dir, zsh
  # Zellij auto-starts from .zshrc and reattaches to existing sessions.
  # -------------------------------------------------------------------------
  _clauded_attach() {
    local _sandbox_name="$1"; shift

    # Get primary workspace from sandbox metadata
    local _ws_path
    _ws_path=$(docker sandbox ls --json 2>/dev/null \
      | jq -r --arg name "$_sandbox_name" '.vms[] | select(.name==$name) | .workspaces[0] // empty')

    local _exec_args=(-it)
    [ -n "$_env_file" ] && _exec_args+=(--env-file "$_env_file")
    [ -n "$_ws_path" ] && _exec_args+=(-w "$_ws_path")

    printf '\033[90m[clauded] docker sandbox exec %s %s /bin/zsh\033[0m\n' "${_exec_args[*]}" "$_sandbox_name"
    docker sandbox exec "${_exec_args[@]}" "$_sandbox_name" /bin/zsh
  }

  # -------------------------------------------------------------------------
  # Interactive sandbox picker
  # -------------------------------------------------------------------------
  local _sandbox_json
  _sandbox_json=$(docker sandbox ls --json 2>/dev/null)

  local _sb_names=() _sb_statuses=() _sb_workspaces=()
  if [ -n "$_sandbox_json" ]; then
    while IFS=$'\t' read -r _name _status _ws; do
      _sb_names+=("$_name")
      _sb_statuses+=("$_status")
      _sb_workspaces+=("$_ws")
    done < <(echo "$_sandbox_json" | jq -r '.vms[] | [.name, .status, (.workspaces[0] // "—")] | @tsv')
  fi

  local _n_sandboxes=${#_sb_names[@]}

  # If rebuild happened, remove existing sandbox and create fresh
  if $_did_rebuild; then
    local _sandbox_name="claude-$(basename "$PWD")"
    if docker sandbox ls 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$_sandbox_name"; then
      printf '\033[1;34m[clauded]\033[0m Removing old sandbox %s to apply new image...\n' "$_sandbox_name"
      docker sandbox rm "$_sandbox_name" 2>/dev/null
    fi
    _clauded_prompt_mounts
    _clauded_create_and_attach "$@"
  elif (( _n_sandboxes == 0 )); then
    _clauded_prompt_mounts
    _clauded_create_and_attach "$@"
  else
    # Build menu: existing sandboxes + New + Cancel
    local _items=()
    for (( i=1; i<=${_n_sandboxes}; i++ )); do
      local _color="\033[32m"
      [[ "${_sb_statuses[$i]}" != "running" ]] && _color="\033[33m"
      local _ws_short="${_sb_workspaces[$i]}"
      (( ${#_ws_short} > 30 )) && _ws_short="…${_ws_short[-30,-1]}"
      _items+=("$(printf '%s  %b%-7s\033[0m  %s' "${_sb_names[$i]}" "$_color" "${_sb_statuses[$i]}" "$_ws_short")")
    done
    _items+=("\033[1;33m+ New sandbox\033[0m — create for $(basename "$PWD")")
    _items+=("Cancel")

    # Default selection: sandbox matching current dir, or "+ New sandbox"
    local _sel=$(( _n_sandboxes + 1 ))
    local _cur_sandbox="claude-$(basename "$PWD")"
    for (( i=1; i<=${_n_sandboxes}; i++ )); do
      if [[ "${_sb_names[$i]}" == "$_cur_sandbox" ]]; then
        _sel=$i
        break
      fi
    done
    local _n=${#_items[@]}

    printf '\033[?25l'

    _clauded_draw_menu() {
      for (( i=1; i<=$_n; i++ )); do
        if (( i == _sel )); then
          printf '\033[2K  \033[1;36m❯ %b\033[0m\n' "${_items[$i]}"
        else
          printf '\033[2K    %b\n' "${_items[$i]}"
        fi
      done
    }

    printf '\033[1;34m[clauded]\033[0m Select a sandbox or create new (↑/↓, Enter, q to cancel):\n'
    _clauded_draw_menu

    while true; do
      read -rsk1 _key
      case "$_key" in
        $'\x1b')
          read -rsk2 _seq
          case "$_seq" in
            '[A') (( _sel > 1 )) && (( _sel-- )) ;;
            '[B') (( _sel < _n )) && (( _sel++ )) ;;
          esac
          ;;
        $'\n'|'') break ;;
        q|Q) _sel=$_n; break ;;
        *) continue ;;
      esac
      printf '\033[%dA\r' "$_n"
      _clauded_draw_menu
    done

    # Clear menu
    printf '\033[%dA\r' "$_n"
    for (( i=1; i<=$_n; i++ )); do printf '\033[2K\n'; done
    printf '\033[%dA' "$_n"
    printf '\033[?25h'
    unfunction _clauded_draw_menu 2>/dev/null

    if (( _sel == _n )); then
      printf '\033[1;34m[clauded]\033[0m Cancelled.\n'
    elif (( _sel == _n - 1 )); then
      _clauded_prompt_mounts
      _clauded_create_and_attach "$@"
    else
      # Selected existing sandbox — action picker
      local _chosen="${_sb_names[$_sel]}"

      local _actions=("Attach  — open zsh (reattaches zellij)"
                      "Delete  — remove sandbox"
                      "Cancel")
      local _asel=1
      local _an=${#_actions[@]}

      printf '\033[?25l'

      _clauded_draw_actions() {
        for (( i=1; i<=$_an; i++ )); do
          if (( i == _asel )); then
            printf '  \033[1;36m❯ %s\033[0m\n' "${_actions[$i]}"
          else
            printf '    %s\n' "${_actions[$i]}"
          fi
        done
      }

      printf '\033[1;34m[clauded]\033[0m \033[1m%s\033[0m — pick action:\n' "$_chosen"
      _clauded_draw_actions

      while true; do
        read -rsk1 _key
        case "$_key" in
          $'\x1b')
            read -rsk2 _seq
            case "$_seq" in
              '[A') (( _asel > 1 )) && (( _asel-- )) ;;
              '[B') (( _asel < _an )) && (( _asel++ )) ;;
            esac
            ;;
          $'\n'|'') break ;;
          q|Q) _asel=$_an; break ;;
          *) continue ;;
        esac
        printf '\033[%dA\r' "$_an"
        _clauded_draw_actions
      done

      # Clear action menu
      printf '\033[%dA\r' "$_an"
      for (( i=1; i<=$_an; i++ )); do printf '\033[2K\n'; done
      printf '\033[%dA' "$_an"
      printf '\033[?25h'
      unfunction _clauded_draw_actions 2>/dev/null

      case $_asel in
        1)
          printf '\033[1;34m[clauded]\033[0m Attaching to \033[1m%s\033[0m...\n' "$_chosen"
          _clauded_attach "$_chosen" "$@"
          ;;
        2)
          printf '\033[1;33m[clauded]\033[0m Remove \033[1m%s\033[0m? [y/N] ' "$_chosen"
          read -rsk1 _confirm
          printf '\n'
          if [[ "$_confirm" == [yY] ]]; then
            docker sandbox rm "$_chosen" 2>/dev/null
            printf '\033[1;34m[clauded]\033[0m Removed \033[1m%s\033[0m.\n' "$_chosen"
          else
            printf '\033[1;34m[clauded]\033[0m Cancelled.\n'
          fi
          ;;
        *)
          printf '\033[1;34m[clauded]\033[0m Cancelled.\n'
          ;;
      esac
    fi
  fi

  _clauded_cleanup
  unfunction _clauded_create_and_attach _clauded_attach _clauded_build_workspaces \
    _clauded_apply_network _clauded_prompt_mounts 2>/dev/null
}

# cll() — shorthand for clauded (interactive sandbox picker)
cll() { clauded "$@"; }

# cls() — alias for cl() (convenience shorthand)
cls() { cl -s "$@"; }

# clsl() — Self-contained launcher for Claude Code with a local model.
#
# On first run, automatically installs llama-server (via Homebrew), sets up a
# downloads the model GGUF via curl (no account needed), and starts the
# inference server. Subsequent runs reuse the existing setup.
#
# Subcommands:
#   clsl              Launch Claude with local model (auto-setup on first run)
#   clsl stop         Stop the background llama-server
#   clsl status       Check if the server is running
#   clsl logs         View server logs
#   clsl help         Show configuration options
#
# All state lives under CLSL_HOME (default: ~/.local/share/clsl).
clsl() {
  local _home="${CLSL_HOME:-$HOME/.local/share/clsl}"
  local _port="${CLSL_PORT:-8080}"
  local _hf_repo="${CLSL_HF_REPO:-Qwen/Qwen3-Coder-Next-GGUF}"
  local _quant="${CLSL_QUANT:-Q4_K_M}"
  local _model_alias="${CLSL_MODEL_ALIAS:-qwen3-coder-next}"
  local _model_dir="$_home/models"
  local _pidfile="$_home/server.pid"
  local _logfile="$_home/server.log"

  # ---------------------------------------------------------------------------
  # Subcommands
  # ---------------------------------------------------------------------------
  case "${1:-}" in
    stop)
      if [[ -f "$_pidfile" ]] && kill -0 "$(cat "$_pidfile")" 2>/dev/null; then
        kill "$(cat "$_pidfile")" && rm -f "$_pidfile"
        printf '[clsl] Server stopped.\n'
      else
        printf '[clsl] No running server found.\n'
        rm -f "$_pidfile"
      fi
      return 0
      ;;
    status)
      if curl -sf "http://localhost:$_port/health" &>/dev/null; then
        printf '[clsl] Server running on port %s\n' "$_port"
      else
        printf '[clsl] Server not running.\n'
      fi
      return 0
      ;;
    logs)
      if [[ -f "$_logfile" ]]; then
        ${PAGER:-less} "$_logfile"
      else
        printf '[clsl] No log file at %s\n' "$_logfile"
      fi
      return 0
      ;;
    help|--help|-h)
      cat <<'HELP'
clsl — self-contained local Claude with Qwen3-Coder-Next

Subcommands:
  clsl              Launch Claude with local model
  clsl stop         Stop the background llama-server
  clsl status       Check if server is running
  clsl logs         View server logs
  clsl help         Show this help

Environment variables (all optional):
  CLSL_HOME          Data directory     (default: ~/.local/share/clsl)
  CLSL_PORT          Server port        (default: 8080)
  CLSL_HF_REPO      HuggingFace repo   (default: Qwen/Qwen3-Coder-Next-GGUF)
  CLSL_QUANT         Quantization       (default: Q4_K_M)
  CLSL_MODEL_ALIAS   Model name for API (default: qwen3-coder-next)
  CLSL_SERVER_ARGS   Extra llama-server flags (space-separated)
HELP
      return 0
      ;;
  esac

  mkdir -p "$_home" "$_model_dir"

  # ---------------------------------------------------------------------------
  # Helper: find GGUF file matching the current quantization.
  # Handles single files and sharded (split) GGUFs.
  # ---------------------------------------------------------------------------
  _clsl_find_gguf() {
    local dir="$1" quant="$2" f=""
    # Single (non-sharded) file matching the quant
    f=$(find "$dir" -name "*${quant}*.gguf" -not -name "*-of-*" 2>/dev/null | head -1)
    [[ -n "$f" ]] && printf '%s' "$f" && return 0
    # First shard of a split GGUF
    f=$(find "$dir" -name "*${quant}*-00001-of-*.gguf" 2>/dev/null | head -1)
    [[ -n "$f" ]] && printf '%s' "$f" && return 0
    # Any GGUF matching the quant (fallback)
    f=$(find "$dir" -name "*${quant}*.gguf" 2>/dev/null | sort | head -1)
    [[ -n "$f" ]] && printf '%s' "$f" && return 0
    return 1
  }

  # ---------------------------------------------------------------------------
  # 1. Ensure llama-server is available
  # ---------------------------------------------------------------------------
  local _server=""
  if command -v llama-server &>/dev/null; then
    _server="llama-server"
  elif [[ -x "$_home/bin/llama-server" ]]; then
    _server="$_home/bin/llama-server"
  else
    printf '[clsl] llama-server not found. Installing via Homebrew...\n'
    if ! command -v brew &>/dev/null; then
      printf '[clsl] ERROR: Homebrew not found. Install llama.cpp manually:\n'
      printf '       https://github.com/ggml-org/llama.cpp#build\n'
      unfunction _clsl_find_gguf 2>/dev/null
      return 1
    fi
    brew install llama.cpp || { unfunction _clsl_find_gguf 2>/dev/null; return 1; }
    _server="llama-server"
  fi

  # ---------------------------------------------------------------------------
  # 2. Ensure model is downloaded (curl + jq, no account needed)
  # ---------------------------------------------------------------------------
  local _gguf_file=""
  _gguf_file=$(_clsl_find_gguf "$_model_dir" "$_quant") || true

  if [[ -z "$_gguf_file" ]]; then
    if ! command -v jq &>/dev/null; then
      printf '[clsl] ERROR: jq is required for model discovery. Install: brew install jq\n'
      unfunction _clsl_find_gguf 2>/dev/null
      return 1
    fi

    local _api="https://huggingface.co/api/models/${_hf_repo}/tree/main"

    printf '[clsl] Looking up %s (quant: %s)...\n' "$_hf_repo" "$_quant"

    # Find the directory matching the quant
    local _quant_dir=""
    _quant_dir=$(curl -sf "$_api" | jq -r ".[] | select(.path | test(\"${_quant}\")) | .path" 2>/dev/null | head -1)

    if [[ -z "$_quant_dir" ]]; then
      printf '[clsl] ERROR: No match for quant "%s" in %s\n' "$_quant" "$_hf_repo"
      printf '       Available:\n'
      curl -sf "$_api" | jq -r '.[] | select(.type == "directory") | "         " + .path' 2>/dev/null
      unfunction _clsl_find_gguf 2>/dev/null
      return 1
    fi

    # List GGUF shard files in that directory
    local _file_list=""
    _file_list=$(curl -sf "${_api}/${_quant_dir}" | jq -r '.[] | select(.path | endswith(".gguf")) | .path' 2>/dev/null)

    if [[ -z "$_file_list" ]]; then
      printf '[clsl] ERROR: No .gguf files found in %s/%s\n' "$_hf_repo" "$_quant_dir"
      unfunction _clsl_find_gguf 2>/dev/null
      return 1
    fi

    local _dl_dir="$_model_dir/$_quant_dir"
    mkdir -p "$_dl_dir"

    local _total=$(echo "$_file_list" | wc -l | tr -d ' ')
    local _current=0

    printf '[clsl] Downloading %d file(s) into %s\n' "$_total" "$_dl_dir"

    while IFS= read -r _fpath; do
      _current=$((_current + 1))
      local _fname="${_fpath##*/}"
      local _url="https://huggingface.co/${_hf_repo}/resolve/main/${_fpath}"
      local _dest="$_dl_dir/$_fname"

      if [[ -f "$_dest" ]]; then
        printf '[clsl] [%d/%d] %s (exists, skipping)\n' "$_current" "$_total" "$_fname"
        continue
      fi

      printf '[clsl] [%d/%d] %s\n' "$_current" "$_total" "$_fname"
      # -C - resumes partial downloads from a previous attempt
      curl -L -C - --progress-bar -o "$_dest.part" "$_url" || {
        printf '[clsl] Download failed: %s\n' "$_fname"
        printf '       Partial file kept at %s.part — will resume on next run.\n' "$_dest"
        unfunction _clsl_find_gguf 2>/dev/null
        return 1
      }
      mv "$_dest.part" "$_dest"
    done <<< "$_file_list"

    _gguf_file=$(_clsl_find_gguf "$_model_dir" "$_quant") || true
    if [[ -z "$_gguf_file" ]]; then
      printf '[clsl] ERROR: No .gguf files found after download.\n'
      unfunction _clsl_find_gguf 2>/dev/null
      return 1
    fi
    printf '[clsl] Model ready: %s\n' "$_gguf_file"
  fi

  unfunction _clsl_find_gguf 2>/dev/null

  # ---------------------------------------------------------------------------
  # 3. Ensure server is running
  # ---------------------------------------------------------------------------
  if ! curl -sf "http://localhost:$_port/health" &>/dev/null; then
    # Clean stale PID file
    if [[ -f "$_pidfile" ]] && ! kill -0 "$(cat "$_pidfile")" 2>/dev/null; then
      rm -f "$_pidfile"
    fi

    printf '[clsl] Starting llama-server on :%s...\n' "$_port"
    "$_server" \
      -m "$_gguf_file" \
      --port "$_port" \
      --alias "$_model_alias" \
      ${=CLSL_SERVER_ARGS} \
      > "$_logfile" 2>&1 &
    echo $! > "$_pidfile"
    disown

    printf '[clsl] Loading model (this may take a minute)...'
    local _tries=120
    while ! curl -sf "http://localhost:$_port/health" &>/dev/null; do
      _tries=$((_tries - 1))
      if [[ $_tries -le 0 ]]; then
        printf '\n[clsl] Server failed to start after 2 min. See: %s\n' "$_logfile"
        return 1
      fi
      printf '.'
      sleep 1
    done
    printf ' ready!\n'
  fi

  # ---------------------------------------------------------------------------
  # 4. Launch Claude
  # ---------------------------------------------------------------------------
  if type cl &>/dev/null; then
    OPENAI_API_KEY="local" \
    OPENAI_BASE_URL="http://localhost:$_port/v1" \
    cl --model "openai:$_model_alias" "$@"
  else
    OPENAI_API_KEY="local" \
    OPENAI_BASE_URL="http://localhost:$_port/v1" \
    command claude --model "openai:$_model_alias" "$@"
  fi
}

# ---------------------------------------------------------------------------
# overwatch / ow — deploy dashboard TUI (gm2211/overwatch)
# Clones the repo if missing; ensures a venv with textual is present.
# ---------------------------------------------------------------------------
overwatch() {
  local _dir="$HOME/projects/overwatch"
  if [ ! -d "$_dir" ]; then
    if [[ ! -o interactive ]]; then
      echo "overwatch: not found at $_dir"
      return 1
    fi
    printf '\033[1;34m[ow]\033[0m Cloning gm2211/overwatch...\n'
    git clone https://github.com/gm2211/overwatch.git "$_dir" || return 1
  fi
  local venv="$_dir/.venv"
  if [[ ! -x "$venv/bin/python3" ]] || ! "$venv/bin/python3" -c "import textual" 2>/dev/null; then
    printf '\033[1;34m[ow]\033[0m Setting up venv...\n'
    python3 -m venv "$venv" && "$venv/bin/pip" install --quiet textual || return 1
  fi
  PYTHONPATH="$_dir" "$venv/bin/python3" -m overwatch "$@"
}

ow() { overwatch "$@"; }

# ---------------------------------------------------------------------------
# bdtui / bdt — beads TUI (gm2211/beads-tui)
# Clones the repo if missing; ensures a venv with textual is present.
# ---------------------------------------------------------------------------
bdtui() {
  local _dir="$HOME/projects/beads-tui"
  if [ ! -d "$_dir" ]; then
    if [[ ! -o interactive ]]; then
      echo "bdtui: not found at $_dir"
      return 1
    fi
    printf '\033[1;34m[bdt]\033[0m Cloning gm2211/beads-tui...\n'
    git clone https://github.com/gm2211/beads-tui.git "$_dir" || return 1
  fi
  local venv="$_dir/.venv"
  if [[ ! -x "$venv/bin/python3" ]] || ! "$venv/bin/python3" -c "import textual" 2>/dev/null; then
    printf '\033[1;34m[bdt]\033[0m Setting up venv...\n'
    python3 -m venv "$venv" && "$venv/bin/pip" install --quiet textual || return 1
  fi
  PYTHONPATH="$_dir" "$venv/bin/python3" -m beads_tui "$@"
}

bdt() { bdtui "$@"; }

# port — interactive port process explorer
#   port           → list all listening ports, pick one to inspect/kill
#   port <number>  → show processes on that port, pick one to kill
#   port kill <n>  → kill all processes on port <n> immediately
port() {
  if ! command -v fzf &>/dev/null; then
    printf '\033[1;31m[port]\033[0m fzf is required: brew install fzf\n'
    return 1
  fi

  local subcmd="$1"
  local port_num="$2"

  # --- port kill <n> — non-interactive kill ---
  if [[ "$subcmd" == "kill" ]]; then
    if [[ -z "$port_num" || ! "$port_num" =~ ^[0-9]+$ ]]; then
      printf '\033[1;31m[port]\033[0m Usage: port kill <port_number>\n'
      return 1
    fi
    local pids
    pids=$(lsof -ti :"$port_num" 2>/dev/null)
    if [[ -z "$pids" ]]; then
      printf '\033[1;33m[port]\033[0m No processes found on port %s\n' "$port_num"
      return 0
    fi
    printf '\033[1;34m[port]\033[0m Killing processes on port %s: %s\n' "$port_num" "$(echo $pids | tr '\n' ' ')"
    echo "$pids" | xargs kill -9
    printf '\033[1;32m[port]\033[0m Done.\n'
    return 0
  fi

  # --- port <n> — interactive view for a specific port ---
  if [[ -n "$subcmd" && "$subcmd" =~ ^[0-9]+$ ]]; then
    port_num="$subcmd"
    local lines
    lines=$(lsof -i :"$port_num" -P -n 2>/dev/null | tail -n +2)
    if [[ -z "$lines" ]]; then
      printf '\033[1;33m[port]\033[0m No processes found on port %s\n' "$port_num"
      return 0
    fi
    local header
    header=$(printf '%-8s %-20s %-6s %-6s %-10s %-8s %s' \
      "PID" "COMMAND" "USER" "FD" "TYPE" "PROTO" "NAME")
    local formatted
    formatted=$(echo "$lines" | awk '{printf "%-8s %-20s %-6s %-6s %-10s %-8s %s\n", $2, $1, $3, $4, $5, $8, $9}')
    local selected
    selected=$(echo "$formatted" | fzf \
      --header="$header"$'\n'"Port $port_num — Enter=kill, Esc=cancel" \
      --multi \
      --ansi \
      --reverse \
      --no-sort)
    [[ -z "$selected" ]] && return 0
    local sel_pids
    sel_pids=$(echo "$selected" | awk '{print $1}' | sort -u)
    echo "$sel_pids" | while read -r pid; do
      local pname
      pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
      printf '\033[1;34m[port]\033[0m Kill PID %s (%s)? [y/N] ' "$pid" "$pname"
      read -rsk1 ans
      printf '\n'
      if [[ "$ans" =~ ^[Yy]$ ]]; then
        kill -9 "$pid" 2>/dev/null && \
          printf '\033[1;32m[port]\033[0m Killed %s\n' "$pid" || \
          printf '\033[1;31m[port]\033[0m Failed to kill %s (try sudo)\n' "$pid"
      fi
    done
    return 0
  fi

  # --- port (no args) — list all listening ports interactively ---
  if [[ -n "$subcmd" ]]; then
    printf '\033[1;31m[port]\033[0m Usage: port [port_number | kill <port_number>]\n'
    return 1
  fi

  local lines
  lines=$(lsof -i -P -n -sTCP:LISTEN 2>/dev/null | tail -n +2)
  if [[ -z "$lines" ]]; then
    printf '\033[1;33m[port]\033[0m No listening ports found.\n'
    return 0
  fi
  local formatted
  formatted=$(echo "$lines" | awk '{
    # extract port from NAME field (e.g. *:3000 or 127.0.0.1:8080)
    split($9, a, ":")
    port = a[length(a)]
    printf "%-7s %-22s %-10s %-6s %s\n", port, $1, $2, $3, $9
  }' | sort -n -k1)
  local header
  header=$(printf '%-7s %-22s %-10s %-6s %s' "PORT" "COMMAND" "PID" "USER" "ADDRESS")
  local selected
  selected=$(echo "$formatted" | fzf \
    --header="$header"$'\n'"Enter=inspect port, Esc=cancel" \
    --ansi \
    --reverse \
    --no-sort)
  [[ -z "$selected" ]] && return 0
  local chosen_port
  chosen_port=$(echo "$selected" | awk '{print $1}')
  # recurse into the single-port view
  port "$chosen_port"
}

# filelock — interactive file lock explorer
#   filelock <file>       → show processes holding the file, pick one to kill
#   filelock kill <file>  → kill all processes holding the file immediately
filelock() {
  if ! command -v fzf &>/dev/null; then
    printf '\033[1;31m[filelock]\033[0m fzf is required: brew install fzf\n'
    return 1
  fi

  local subcmd="$1"
  local target="$2"

  # --- filelock kill <file> — non-interactive kill ---
  if [[ "$subcmd" == "kill" ]]; then
    if [[ -z "$target" ]]; then
      printf '\033[1;31m[filelock]\033[0m Usage: filelock kill <file>\n'
      return 1
    fi
    target=$(realpath "$target" 2>/dev/null || echo "$target")
    local pids
    pids=$(lsof -t "$target" 2>/dev/null)
    if [[ -z "$pids" ]]; then
      printf '\033[1;33m[filelock]\033[0m No processes found holding %s\n' "$target"
      return 0
    fi
    printf '\033[1;34m[filelock]\033[0m Killing processes holding %s: %s\n' "$target" "$(echo $pids | tr '\n' ' ')"
    echo "$pids" | xargs kill -9
    printf '\033[1;32m[filelock]\033[0m Done.\n'
    return 0
  fi

  # --- filelock <file> — interactive view ---
  if [[ -n "$subcmd" ]]; then
    target="$subcmd"
    target=$(realpath "$target" 2>/dev/null || echo "$target")
    if [[ ! -e "$target" ]]; then
      printf '\033[1;31m[filelock]\033[0m File not found: %s\n' "$target"
      return 1
    fi
    local lines
    lines=$(lsof "$target" 2>/dev/null | tail -n +2)
    if [[ -z "$lines" ]]; then
      printf '\033[1;33m[filelock]\033[0m No processes found holding %s\n' "$target"
      return 0
    fi
    local header
    header=$(printf '%-8s %-20s %-6s %-6s %-10s %s' \
      "PID" "COMMAND" "USER" "FD" "TYPE" "LOCK")
    local formatted
    formatted=$(echo "$lines" | awk '{printf "%-8s %-20s %-6s %-6s %-10s %s\n", $2, $1, $3, $4, $5, $8}')
    local selected
    selected=$(echo "$formatted" | fzf \
      --header="$header"$'\n'"$(basename "$target") — Enter=kill, Esc=cancel" \
      --multi \
      --ansi \
      --reverse \
      --no-sort)
    [[ -z "$selected" ]] && return 0
    local sel_pids
    sel_pids=$(echo "$selected" | awk '{print $1}' | sort -u)
    echo "$sel_pids" | while read -r pid; do
      local pname
      pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
      printf '\033[1;34m[filelock]\033[0m Kill PID %s (%s)? [y/N] ' "$pid" "$pname"
      read -rsk1 ans
      printf '\n'
      if [[ "$ans" =~ ^[Yy]$ ]]; then
        kill -9 "$pid" 2>/dev/null && \
          printf '\033[1;32m[filelock]\033[0m Killed %s\n' "$pid" || \
          printf '\033[1;31m[filelock]\033[0m Failed to kill %s (try sudo)\n' "$pid"
      fi
    done
    return 0
  fi

  printf '\033[1;31m[filelock]\033[0m Usage: filelock <file> | filelock kill <file>\n'
  return 1
}

function k9() { kill -9 $1 }

# sb — strip blanks (all whitespace) from a string
# Usage: sb "  hello  world  "  →  "helloworld"
#        echo " foo bar " | sb
sb() {
  local result
  if [ $# -gt 0 ]; then
    result=$(printf '%s' "${*//$'\n'/}" | tr -d '[:space:]')
  else
    result=$(tr -d '[:space:]')
  fi
  printf '%s' "$result" | pbcopy
  printf '%s\n' "$result"
}
