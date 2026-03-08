#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# launch.sh — Host-side interactive launcher for Claude in Docker
# ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# docker/ now lives inside the plugin dir; climb 3 levels to reach the repo root
# plugins/claude-multiagent/docker -> plugins/claude-multiagent -> plugins -> repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
IMAGE_NAME="claude-multiagent"

# ── Color helpers ─────────────────────────────────────────────

info()    { printf "\033[1;34m[INFO]\033[0m  %b\n" "$*"; }
success() { printf "\033[1;32m[OK]\033[0m    %b\n" "$*"; }
warn()    { printf "\033[1;33m[WARN]\033[0m  %b\n" "$*"; }
error()   { printf "\033[1;31m[ERROR]\033[0m %b\n" "$*" >&2; }
die()     { error "$@"; exit 1; }

# ── CLI Argument Parsing ──────────────────────────────────────

REPO=""
FORCE_REBUILD="false"
CLAUDE_PROMPT=""
REPO_BRANCH=""
CLAUDE_MODEL=""
MAX_BUDGET_USD=""
ATTACH_MODE="false"
DELETE_MODE="false"
NO_PUSH="false"
GH_AVAILABLE="false"
PERSIST_REPO="false"

usage() {
    cat <<'USAGE'
Usage: launch.sh [OPTIONS] [REPO]

Launch a sandboxed Claude Code instance in Docker for a specific repo.

Options:
  --rebuild     Force rebuild the Docker image
  --attach      List running containers and attach to one (interactive TUI)
  --delete      Open interactive TUI focused on container deletion
  --no-push     Autonomous mode: commits local only, no git push
  --persistent  Reuse a per-repo Docker volume instead of fresh clone
  --prompt CMD  Run non-interactively with this prompt
  --branch BR   Checkout this branch
  --model MOD   Use this Claude model
  --budget USD  Set max API budget
  -h, --help    Show this help

Examples:
  launch.sh                          # Interactive wizard
  launch.sh owner/repo               # Quick launch for a specific repo
  launch.sh --attach                 # Attach to a running container
  launch.sh --delete                 # Delete containers interactively
  launch.sh --prompt "fix tests" owner/repo  # Non-interactive
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --rebuild)
                FORCE_REBUILD="true"
                shift
                ;;
            --attach)
                ATTACH_MODE="true"
                shift
                ;;
            --delete)
                DELETE_MODE="true"
                shift
                ;;
            --no-push)
                NO_PUSH="true"
                shift
                ;;
            --persistent)
                PERSIST_REPO="true"
                shift
                ;;
            --prompt=*)
                CLAUDE_PROMPT="${1#--prompt=}"
                shift
                ;;
            --prompt)
                CLAUDE_PROMPT="${2:?--prompt requires a value}"
                shift 2
                ;;
            --branch=*)
                REPO_BRANCH="${1#--branch=}"
                shift
                ;;
            --branch)
                REPO_BRANCH="${2:?--branch requires a value}"
                shift 2
                ;;
            --model=*)
                CLAUDE_MODEL="${1#--model=}"
                shift
                ;;
            --model)
                CLAUDE_MODEL="${2:?--model requires a value}"
                shift 2
                ;;
            --budget=*)
                MAX_BUDGET_USD="${1#--budget=}"
                shift
                ;;
            --budget)
                MAX_BUDGET_USD="${2:?--budget requires a value}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                die "Unknown option: $1\nRun launch.sh --help for usage."
                ;;
            *)
                REPO="$1"
                shift
                ;;
        esac
    done
}

# ── Step 1: Check Prerequisites ──────────────────────────────

check_prerequisites() {
    if ! command -v docker &>/dev/null; then
        die "Docker is not installed. Install it from https://docker.com/get-started"
    fi

    if ! docker info &>/dev/null; then
        die "Docker daemon is not running. Start Docker Desktop and try again."
    fi

    if command -v gh &>/dev/null; then
        GH_AVAILABLE="true"
    else
        GH_AVAILABLE="false"
        warn "GitHub CLI (gh) not found. Falling back to GH_TOKEN/manual repo mode."
    fi
}

# ── Step 2: GitHub Authentication ─────────────────────────────

ensure_gh_auth() {
    if [ -n "${GH_TOKEN:-}" ]; then
        success "Using GH_TOKEN from environment"
        return 0
    fi

    if [ "$GH_AVAILABLE" != "true" ]; then
        die "GH_TOKEN is not set and GitHub CLI (gh) is not installed.\n  Install gh: brew install gh\n  Or set GH_TOKEN and rerun."
    fi

    if gh auth status &>/dev/null; then
        success "GitHub CLI authenticated"
        return 0
    fi

    if ! _tty_available; then
        die "No GH_TOKEN set and gh is not authenticated in a non-interactive shell.\n  Run 'gh auth login' first, or set GH_TOKEN."
    fi

    info "GitHub authentication required. Using device code flow (no browser needed)."
    info "You will be given a one-time code to enter at https://github.com/login/device"
    echo ""

    gh auth login --git-protocol https --scopes repo

    if ! gh auth status &>/dev/null; then
        die "GitHub authentication failed"
    fi
    success "GitHub authenticated successfully"
}

# ── Container Detection & Attachment ─────────────────────────

container_rows() {
    local cid found
    found="false"

    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        local repo repo_display name status prompt_value
        repo=$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^REPO=' | cut -d= -f2- || true)
        prompt_value=$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^CLAUDE_PROMPT=' | cut -d= -f2- || true)

        # Only show containers that are expected to be attachable shells.
        # Task containers launched with CLAUDE_PROMPT are intentionally excluded.
        if [ -n "${prompt_value:-}" ]; then
            continue
        fi

        found="true"
        if [[ "${repo:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
            repo_display="$repo"
        else
            repo_display="custom"
        fi
        name=$(docker inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's|^/||' || true)
        status=$(docker ps -a --filter "id=$cid" --format '{{.Status}}' 2>/dev/null || true)
        printf '%s\t%s\t%s\t%s\n' "$cid" "${name:-$cid}" "${repo_display:-custom}" "${status:-unknown}"
    done < <(docker ps -a --filter "ancestor=$IMAGE_NAME" --format '{{.ID}}' 2>/dev/null)

    [ "$found" = "true" ] || return 1
}

print_container_table() {
    local rows="$1"
    local i=1
    echo ""
    info "Existing claude-multiagent containers:"
    echo ""
    printf "  %3s  %-20s  %-30s  %s\n" "#" "NAME" "REPO" "STATUS"
    printf "  %3s  %-20s  %-30s  %s\n" "---" "--------------------" "------------------------------" "--------"
    while IFS=$'\t' read -r _cid name repo status; do
        printf "  %3d  %-20s  %-30s  %s\n" "$i" "$name" "$repo" "$status"
        ((i++))
    done <<< "$rows"
}

attach_to_container() {
    local cid="$1"
    local state
    state=$(docker inspect "$cid" --format '{{.State.Status}}' 2>/dev/null || true)

    if [ "$state" = "exited" ] || [ "$state" = "created" ]; then
        info "Restarting stopped container..."
        docker start "$cid" >/dev/null
        # Wait briefly for entrypoint to initialize
        sleep 1
    fi

    info "Attaching to container..."
    exec docker exec -it "$cid" /bin/zsh -l
}

_tty_available() {
    [ -t 0 ] || { [ -e /dev/tty ] && : </dev/tty 2>/dev/null; }
}

_use_fzf() {
    [ "${MULTIAGENT_USE_FZF:-0}" = "1" ] && _tty_available && command -v fzf >/dev/null 2>&1
}

repo_volume_name() {
    local slug
    slug=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g')
    printf 'claude-repo-%s' "$slug"
}

# ── Interactive Container Picker TUI ──────────────────────────

interactive_container_picker() {
    # Usage: interactive_container_picker <rows> <allow_new> [<initial_action>]
    #   rows         - tab-delimited container rows from container_rows()
    #   allow_new    - "true" to show the "n: new" option
    #   initial_action - optional: "delete" to highlight delete on first render
    # Returns:
    #   0 if a container was attached (exec replaces process)
    #   1 if user chose "new" (only when allow_new=true)
    #   2 if user quit/cancelled

    local rows="$1"
    local allow_new="${2:-false}"
    local initial_action="${3:-}"

    # Parse rows into arrays
    local -a cids=() names=() repos=() statuses=()
    while IFS=$'\t' read -r cid name repo status; do
        [ -z "$cid" ] && continue
        cids+=("$cid")
        names+=("$name")
        repos+=("$repo")
        statuses+=("$status")
    done <<< "$rows"

    local total=${#cids[@]}
    if [ "$total" -eq 0 ]; then
        return 2
    fi

    local selected=0
    local message=""
    local message_color=""
    local confirm_delete=""  # index being confirmed for deletion, or empty
    local need_redraw="true"

    # ANSI color codes
    local c_reset="\033[0m"
    local c_bold="\033[1m"
    local c_blue="\033[1;34m"
    local c_green="\033[1;32m"
    local c_yellow="\033[1;33m"
    local c_red="\033[1;31m"
    local c_cyan="\033[1;36m"
    local c_dim="\033[2m"
    local c_reverse="\033[7m"

    # Check tput availability for cursor control
    local has_tput="false"
    command -v tput >/dev/null 2>&1 && has_tput="true"

    _tui_clear_screen() {
        if [ "$has_tput" = "true" ]; then
            tput clear 2>/dev/null || printf '\033[2J\033[H'
        else
            printf '\033[2J\033[H'
        fi
    }

    _tui_hide_cursor() {
        if [ "$has_tput" = "true" ]; then
            tput civis 2>/dev/null || printf '\033[?25l'
        else
            printf '\033[?25l'
        fi
    }

    _tui_show_cursor() {
        if [ "$has_tput" = "true" ]; then
            tput cnorm 2>/dev/null || printf '\033[?25h'
        else
            printf '\033[?25h'
        fi
    }

    _tui_cleanup() {
        _tui_show_cursor
        # Restore terminal settings if stty was modified
        if [ -n "${_tui_old_stty:-}" ]; then
            stty "$_tui_old_stty" 2>/dev/null </dev/tty || true
        fi
    }

    # Save terminal state and set up cleanup
    local _tui_old_stty=""
    _tui_old_stty=$(stty -g </dev/tty 2>/dev/null || true)
    trap '_tui_cleanup' EXIT INT TERM

    _tui_hide_cursor

    _tui_render() {
        _tui_clear_screen

        # Header
        printf "${c_blue}${c_bold}  Claude Multi-Agent — Container Manager${c_reset}\n"
        printf "${c_dim}  ────────────────────────────────────────────────────────────────${c_reset}\n"
        printf "\n"

        # Column headers
        printf "  ${c_dim}%-22s  %-30s  %s${c_reset}\n" "NAME" "REPO" "STATUS"
        printf "  ${c_dim}%-22s  %-30s  %s${c_reset}\n" "──────────────────────" "──────────────────────────────" "────────────────"

        # Container list
        local i
        for ((i = 0; i < total; i++)); do
            local prefix="  "
            local name_display="${names[$i]}"
            local repo_display="${repos[$i]}"
            local status_display="${statuses[$i]}"

            # Truncate long fields
            [ ${#name_display} -gt 22 ] && name_display="${name_display:0:19}..."
            [ ${#repo_display} -gt 30 ] && repo_display="${repo_display:0:27}..."

            if [ "$i" -eq "$selected" ]; then
                if [ "$confirm_delete" = "$i" ]; then
                    # Highlighted + pending delete confirmation
                    printf "${c_red}${c_reverse}${c_bold}> %-22s  %-30s  %s${c_reset}\n" "$name_display" "$repo_display" "$status_display"
                else
                    printf "${c_cyan}${c_reverse}${c_bold}> %-22s  %-30s  %s${c_reset}\n" "$name_display" "$repo_display" "$status_display"
                fi
            else
                printf "  %-22s  %-30s  %s\n" "$name_display" "$repo_display" "$status_display"
            fi
        done

        printf "\n"

        # Status / message line
        if [ -n "$confirm_delete" ]; then
            printf "  ${c_red}${c_bold}Delete '${names[$confirm_delete]}'? Press d/x again to confirm, any other key to cancel${c_reset}\n"
        elif [ -n "$message" ]; then
            printf "  ${message_color}${message}${c_reset}\n"
        else
            printf "\n"
        fi

        printf "\n"

        # Help bar
        local help_line="  ${c_dim}↑↓/jk: navigate  │  Enter/a: attach  │  d/x: delete"
        if [ "$allow_new" = "true" ]; then
            help_line="${help_line}  │  n: new"
        fi
        help_line="${help_line}  │  q/Esc: quit${c_reset}"
        printf "%b\n" "$help_line"
    }

    # Initial render
    _tui_render

    # Main input loop
    while true; do
        local key=""
        # Read a single character from /dev/tty in raw mode
        IFS= read -rsn1 key </dev/tty 2>/dev/null || true

        # Handle escape sequences (arrow keys)
        if [ "$key" = $'\x1b' ]; then
            local seq1="" seq2=""
            IFS= read -rsn1 -t 1 seq1 </dev/tty 2>/dev/null || true
            if [ "$seq1" = "[" ]; then
                IFS= read -rsn1 -t 1 seq2 </dev/tty 2>/dev/null || true
                case "$seq2" in
                    A) key="UP" ;;    # Up arrow
                    B) key="DOWN" ;;  # Down arrow
                    *) key="ESC" ;;   # Other escape sequence
                esac
            else
                key="ESC"  # Plain Escape
            fi
        fi

        # If we're in delete confirmation mode, handle it specially
        if [ -n "$confirm_delete" ]; then
            if [ "$key" = "d" ] || [ "$key" = "x" ]; then
                # Confirmed: delete the container
                local del_cid="${cids[$confirm_delete]}"
                local del_name="${names[$confirm_delete]}"
                message="Deleting '${del_name}'..."
                message_color="$c_yellow"
                confirm_delete=""
                _tui_render

                docker stop "$del_cid" 2>/dev/null || true
                docker rm "$del_cid" 2>/dev/null || true

                # Remove from arrays
                local -a new_cids=() new_names=() new_repos=() new_statuses=()
                local idx
                for ((idx = 0; idx < total; idx++)); do
                    if [ "$idx" -ne "$selected" ]; then
                        new_cids+=("${cids[$idx]}")
                        new_names+=("${names[$idx]}")
                        new_repos+=("${repos[$idx]}")
                        new_statuses+=("${statuses[$idx]}")
                    fi
                done
                cids=("${new_cids[@]+"${new_cids[@]}"}")
                names=("${new_names[@]+"${new_names[@]}"}")
                repos=("${new_repos[@]+"${new_repos[@]}"}")
                statuses=("${new_statuses[@]+"${new_statuses[@]}"}")
                total=${#cids[@]}

                if [ "$total" -eq 0 ]; then
                    _tui_cleanup
                    trap - EXIT INT TERM
                    success "Container '${del_name}' deleted. No containers remaining."
                    return 2
                fi

                # Adjust selection index
                if [ "$selected" -ge "$total" ]; then
                    selected=$((total - 1))
                fi

                message="Deleted '${del_name}'"
                message_color="$c_green"
                _tui_render
                continue
            else
                # Cancelled
                confirm_delete=""
                message="Delete cancelled"
                message_color="$c_dim"
                _tui_render
                continue
            fi
        fi

        # Normal mode key handling
        case "$key" in
            UP|k)
                if [ "$selected" -gt 0 ]; then
                    ((selected--))
                fi
                message=""
                _tui_render
                ;;
            DOWN|j)
                if [ "$selected" -lt $((total - 1)) ]; then
                    ((selected++))
                fi
                message=""
                _tui_render
                ;;
            ""|a)  # Enter key reads as empty string; 'a' for attach
                _tui_cleanup
                trap - EXIT INT TERM
                attach_to_container "${cids[$selected]}"
                return 0  # attach_to_container does exec, but just in case
                ;;
            d|x)
                confirm_delete="$selected"
                _tui_render
                ;;
            n)
                if [ "$allow_new" = "true" ]; then
                    _tui_cleanup
                    trap - EXIT INT TERM
                    return 1
                fi
                # In attach-only mode, 'n' does nothing
                message="New container not available in this mode"
                message_color="$c_dim"
                _tui_render
                ;;
            q|ESC)
                _tui_cleanup
                trap - EXIT INT TERM
                return 2
                ;;
            *)
                # Ignore unknown keys
                ;;
        esac
    done
}

interactive_repo_picker() {
    # Usage: interactive_repo_picker <newline-delimited repo list>
    # Sets global REPO to the selected repository.
    # Returns:
    #   0 if a repo was selected (REPO is set)
    #   1 if user quit/cancelled

    local repo_list="$1"

    # Parse repos into array
    local -a repo_items=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        repo_items+=("$line")
    done <<< "$repo_list"

    local total=${#repo_items[@]}
    if [ "$total" -eq 0 ]; then
        return 1
    fi

    local selected=0
    local message=""
    local message_color=""

    # ANSI color codes
    local c_reset="\033[0m"
    local c_bold="\033[1m"
    local c_blue="\033[1;34m"
    local c_cyan="\033[1;36m"
    local c_dim="\033[2m"
    local c_reverse="\033[7m"

    # Check tput availability for cursor control
    local has_tput="false"
    command -v tput >/dev/null 2>&1 && has_tput="true"

    _rp_clear_screen() {
        if [ "$has_tput" = "true" ]; then
            tput clear 2>/dev/null || printf '\033[2J\033[H'
        else
            printf '\033[2J\033[H'
        fi
    }

    _rp_hide_cursor() {
        if [ "$has_tput" = "true" ]; then
            tput civis 2>/dev/null || printf '\033[?25l'
        else
            printf '\033[?25l'
        fi
    }

    _rp_show_cursor() {
        if [ "$has_tput" = "true" ]; then
            tput cnorm 2>/dev/null || printf '\033[?25h'
        else
            printf '\033[?25h'
        fi
    }

    _rp_cleanup() {
        _rp_show_cursor
        if [ -n "${_rp_old_stty:-}" ]; then
            stty "$_rp_old_stty" 2>/dev/null </dev/tty || true
        fi
    }

    # Save terminal state and set up cleanup
    local _rp_old_stty=""
    _rp_old_stty=$(stty -g </dev/tty 2>/dev/null || true)
    trap '_rp_cleanup' EXIT INT TERM

    _rp_hide_cursor

    _rp_render() {
        _rp_clear_screen

        # Header
        printf "${c_blue}${c_bold}  Claude Multi-Agent — Repository Picker${c_reset}\n"
        printf "${c_dim}  ────────────────────────────────────────────────────────────────${c_reset}\n"
        printf "\n"

        # Repo list
        local i
        for ((i = 0; i < total; i++)); do
            if [ "$i" -eq "$selected" ]; then
                printf "${c_cyan}${c_reverse}${c_bold}> %s${c_reset}\n" "${repo_items[$i]}"
            else
                printf "  %s\n" "${repo_items[$i]}"
            fi
        done

        printf "\n"

        # Message line
        if [ -n "$message" ]; then
            printf "  ${message_color}${message}${c_reset}\n"
        else
            printf "\n"
        fi

        printf "\n"

        # Help bar
        printf "  ${c_dim}↑↓/jk: navigate  │  Enter: select  │  /: type manually  │  q/Esc: quit${c_reset}\n"
    }

    # Initial render
    _rp_render

    # Main input loop
    while true; do
        local key=""
        IFS= read -rsn1 key </dev/tty 2>/dev/null || true

        # Handle escape sequences (arrow keys)
        if [ "$key" = $'\x1b' ]; then
            local seq1="" seq2=""
            IFS= read -rsn1 -t 1 seq1 </dev/tty 2>/dev/null || true
            if [ "$seq1" = "[" ]; then
                IFS= read -rsn1 -t 1 seq2 </dev/tty 2>/dev/null || true
                case "$seq2" in
                    A) key="UP" ;;
                    B) key="DOWN" ;;
                    *) key="ESC" ;;
                esac
            else
                key="ESC"
            fi
        fi

        case "$key" in
            UP|k)
                if [ "$selected" -gt 0 ]; then
                    ((selected--))
                fi
                message=""
                _rp_render
                ;;
            DOWN|j)
                if [ "$selected" -lt $((total - 1)) ]; then
                    ((selected++))
                fi
                message=""
                _rp_render
                ;;
            "")  # Enter key
                REPO="${repo_items[$selected]}"
                _rp_cleanup
                trap - EXIT INT TERM
                return 0
                ;;
            /|t)  # Type manually
                _rp_show_cursor
                if [ -n "${_rp_old_stty:-}" ]; then
                    stty "$_rp_old_stty" 2>/dev/null </dev/tty || true
                fi
                _rp_clear_screen
                printf "${c_blue}${c_bold}  Claude Multi-Agent — Repository Picker${c_reset}\n"
                printf "${c_dim}  ────────────────────────────────────────────────────────────────${c_reset}\n"
                printf "\n"
                printf "  Enter repository (owner/repo): "
                read -r REPO </dev/tty
                trap - EXIT INT TERM
                return 0
                ;;
            q|ESC)
                _rp_cleanup
                trap - EXIT INT TERM
                return 1
                ;;
            *)
                # Ignore unknown keys
                ;;
        esac
    done
}

select_container_and_attach() {
    local rows="$1"
    local allow_new="${2:-false}"
    local initial_action="${3:-}"
    if _use_fzf; then
        local selected
        selected=$(printf '%s\n' "$rows" | fzf --height=~50% --reverse \
            --delimiter=$'\t' --with-nth=2,3,4 \
            --prompt="Select container to attach: " \
            --header="Arrow keys to navigate, Enter to select, Esc for new launch" \
            2>/dev/null </dev/tty)
        local fzf_exit=$?
        if [ "$fzf_exit" -ne 0 ] || [ -z "$selected" ]; then
            [ "$allow_new" = "true" ] && return 1
            die "No container selected."
        fi
        attach_to_container "$(printf '%s' "$selected" | cut -f1)"
        return 0
    fi

    if _tty_available; then
        local picker_result=0
        interactive_container_picker "$rows" "$allow_new" "$initial_action" || picker_result=$?
        case $picker_result in
            0) return 0 ;;  # Attached (exec replaces process)
            1) return 1 ;;  # User chose "new"
            2)              # User quit
                [ "$allow_new" = "true" ] && return 1
                die "No container selected."
                ;;
        esac
        return 0
    fi

    [ "$allow_new" = "true" ] && return 1
    error "No TTY available for interactive selection."
    die "Run launch.sh --attach in an interactive terminal."
}

check_existing_containers() {
    local initial_action="${1:-}"
    local rows
    if ! rows="$(container_rows)"; then
        die "No containers found. Launch a new one without --attach."
    fi

    select_container_and_attach "$rows" "false" "$initial_action"
}

maybe_attach_existing_containers() {
    local rows
    rows="$(container_rows 2>/dev/null || true)"
    [ -n "$rows" ] || return 0

    if select_container_and_attach "$rows" "true"; then
        return 0
    fi
    info "Starting a new container launch..."
}

# ── Step 3: Repo Selection ────────────────────────────────────

select_repo() {
    # If REPO was set via CLI arg, validate and return
    if [ -n "${REPO:-}" ]; then
        info "Target repo: $REPO"
        return 0
    fi

    echo ""
    info "Select a repository:"
    echo ""

    # Fetch recent repos (when gh is available); otherwise manual entry.
    local repos
    repos=""
    if [ "$GH_AVAILABLE" = "true" ]; then
        repos=$(gh repo list --limit 15 --json nameWithOwner -q '.[].nameWithOwner' 2>/dev/null || true)
    fi

    if [ -n "$repos" ]; then
        local repo_array=()
        while IFS= read -r repo; do
            repo_array+=("$repo")
        done <<< "$repos"

        if _use_fzf; then
            # fzf mode
            local selected
            selected=$(printf '%s\n' "${repo_array[@]}" | fzf --height=~50% --reverse \
                --prompt="Select repo: " \
                --header="Arrow keys to navigate, Enter to select, Esc to type manually" \
                2>/dev/null </dev/tty)
            local fzf_exit=$?
            if [ "$fzf_exit" -eq 0 ] && [ -n "$selected" ]; then
                REPO="$selected"
            else
                # Esc pressed — let user type manually
                printf "  Enter repository (owner/repo): "
                read -r REPO </dev/tty
            fi
        elif _tty_available; then
            if ! interactive_repo_picker "$repos"; then
                die "No repository selected"
            fi
        else
            # No TTY — cannot interactively select
            error "No TTY available for interactive repo selection."
            die "Pass a repo directly: launch.sh owner/repo"
        fi
    else
        if _tty_available; then
            printf "  Enter repository (owner/repo): "
            read -r REPO </dev/tty
        else
            die "No repos found and no TTY available. Pass a repo directly: launch.sh owner/repo"
        fi
    fi

    if [ -z "$REPO" ]; then
        die "No repository selected"
    fi

    success "Selected: $REPO"
}

# ── Step 4: Anthropic API Key ─────────────────────────────────

ensure_api_key() {
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        success "Anthropic API key found in environment"
        return 0
    fi

    warn "No ANTHROPIC_API_KEY in environment"
    info "You can authenticate inside the container with 'claude login'"
    echo ""
    printf "  Enter API key now (or press Enter to skip): "
    read -rs ANTHROPIC_API_KEY
    echo ""

    if [ -n "$ANTHROPIC_API_KEY" ]; then
        export ANTHROPIC_API_KEY
        success "API key set"
    else
        info "Skipping — authenticate inside the container"
    fi
}

# ── Step 5b: Auto-rebuild Detection ──────────────────────────

compute_source_hash() {
    find "$REPO_ROOT/plugins/claude-multiagent/docker/Dockerfile" \
         "$REPO_ROOT/plugins/claude-multiagent/docker/entrypoint.sh" \
         "$REPO_ROOT/shell-configs/" \
         -type f -print0 \
        | sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256 \
        | cut -c1-12
}

check_image_freshness() {
    # Skip if the image doesn't exist yet (build_image will handle it)
    docker image inspect "$IMAGE_NAME" &>/dev/null || return 0

    local image_hash current_hash
    image_hash=$(docker inspect --format '{{index .Config.Labels "source_hash"}}' "$IMAGE_NAME" 2>/dev/null || true)
    current_hash=$(compute_source_hash)

    if [ "$image_hash" = "$current_hash" ] && [ -n "$image_hash" ]; then
        return 0
    fi

    warn "Docker image is out of date (image: ${image_hash:-none}, current: ${current_hash})"

    if _tty_available; then
        read -rp "Rebuild now? [Y/n] " answer </dev/tty
    else
        # Non-interactive: default to rebuild
        answer=""
    fi

    if [ -z "$answer" ] || [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        FORCE_REBUILD="true"
    else
        info "Continuing with stale image. Run 'clauded --rebuild' to update."
    fi
}

# ── Step 6: Build Image ──────────────────────────────────────

build_image() {
    local force="${1:-false}"

    if [ "$force" = "true" ] || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        info "Building Docker image..."
        docker build -t "$IMAGE_NAME" \
            --build-arg SOURCE_HASH="$(compute_source_hash)" \
            -f "$SCRIPT_DIR/Dockerfile" "$REPO_ROOT"
        success "Image built successfully"
    else
        info "Using existing image (use --rebuild to force)"
    fi
}

# ── Step 7: Launch Container ─────────────────────────────────

launch_container() {
    # Generate a container name from the repo
    local container_name
    local repo_volume=""
    container_name="claude-$(echo "$REPO" | tr '/' '-' | tr '.' '-')"
    if [ "$PERSIST_REPO" = "true" ]; then
        repo_volume="$(repo_volume_name)"
    fi

    # If a same-name container is already running, reuse it instead of failing
    local existing_state
    local existing_prompt
    existing_state=$(docker inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || true)
    existing_prompt=$(docker inspect "$container_name" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^CLAUDE_PROMPT=' | cut -d= -f2- || true)
    if [ "$existing_state" = "running" ]; then
        if [ -n "${existing_prompt:-}" ]; then
            die "Container '$container_name' is a task container (CLAUDE_PROMPT set) and is not attachable. Stop it first."
        fi
        if [ -n "${CLAUDE_PROMPT:-}" ]; then
            die "Container '$container_name' is already running. Stop it first, or run --attach."
        fi
        info "Container '$container_name' is already running. Attaching..."
        exec docker exec -it "$container_name" /bin/zsh -l
    fi

    # Remove stopped container with same name if it exists
    if [ "$existing_state" = "exited" ] || [ "$existing_state" = "created" ]; then
        docker rm "$container_name" 2>/dev/null || true
    fi

    local docker_args=(
        "run" "-d"
        "--name" "$container_name"
        "-e" "GH_TOKEN=$GH_TOKEN"
        "-e" "REPO=$REPO"
        "--memory=4g"
        "--cpus=2"
        "--tmpfs" "/tmp:rw,noexec,nosuid,size=512m"
        # Security hardening
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges"
        "--pids-limit=1024"
        # NOTE: --read-only is intentionally omitted. The container's entrypoint
        # writes to numerous paths at runtime (git config in $HOME, .claude/
        # settings, repo clone, node_modules, npm cache, etc.). Enumerating all
        # writable paths as tmpfs/volume mounts is fragile and breaks when
        # Claude Code or npm update their internal paths. The container already
        # runs with --cap-drop=ALL and --security-opt=no-new-privileges, which
        # prevent privilege escalation even with a writable filesystem.
    )

    # Optional env vars
    [ -n "${ANTHROPIC_API_KEY:-}" ] && docker_args+=("-e" "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    [ -n "${RENDER_API_KEY:-}" ] && docker_args+=("-e" "RENDER_API_KEY=$RENDER_API_KEY")
    [ -n "${REPO_BRANCH:-}" ] && docker_args+=("-e" "REPO_BRANCH=$REPO_BRANCH")
    [ -n "${CLAUDE_MODEL:-}" ] && docker_args+=("-e" "CLAUDE_MODEL=$CLAUDE_MODEL")
    [ -n "${MAX_BUDGET_USD:-}" ] && docker_args+=("-e" "MAX_BUDGET_USD=$MAX_BUDGET_USD")

    if [ -n "${CLAUDE_PROMPT:-}" ]; then
        docker_args+=("-e" "CLAUDE_PROMPT=$CLAUDE_PROMPT")
    fi

    [ "$NO_PUSH" = "true" ] && docker_args+=("-e" "NO_PUSH=true")
    if [ "$PERSIST_REPO" = "true" ]; then
        docker_args+=("-e" "PERSIST_REPO=true")
        docker_args+=("-v" "${repo_volume}:/home/claude/repo")
    fi

    docker_args+=("$IMAGE_NAME")

    # Show summary
    echo ""
    info "════════════════════════════════════════"
    info "  Launching Claude Code"
    info "  Repo:   $REPO"
    info "  Container: $container_name"
    [ -n "${REPO_BRANCH:-}" ] && info "  Branch: $REPO_BRANCH"
    [ -n "${CLAUDE_MODEL:-}" ] && info "  Model:  $CLAUDE_MODEL"
    [ -n "${CLAUDE_PROMPT:-}" ] && info "  Prompt: $CLAUDE_PROMPT"
    [ "$NO_PUSH" = "true" ] && info "  Mode:   NO PUSH (autonomous, commits local only)"
    [ "$PERSIST_REPO" = "true" ] && info "  Mode:   PERSISTENT repo volume (${repo_volume})"
    info "════════════════════════════════════════"
    echo ""

    # Start container detached
    local cid
    cid=$(docker "${docker_args[@]}")
    info "Container started: ${cid:0:12}"

    # Wait for entrypoint to finish setup
    info "Waiting for setup to complete..."
    local attempts=0
    while [ $attempts -lt 60 ]; do
        # Check if container is still running (entrypoint might have failed)
        local state
        state=$(docker inspect "$cid" --format '{{.State.Status}}' 2>/dev/null || echo "gone")
        if [ "$state" = "exited" ] || [ "$state" = "gone" ]; then
            error "Container exited during setup. Logs:"
            docker logs "$cid" 2>&1 | tail -20
            exit 1
        fi

        # Check if setup is done (entrypoint writes readiness sentinel)
        if docker exec "$cid" test -f /tmp/claude-ready 2>/dev/null; then
            break
        fi

        sleep 1
        ((attempts++))
    done

    if [ $attempts -ge 60 ]; then
        die "Container setup timed out"
    fi

    success "Container ready"

    # Non-interactive mode: just tail logs
    if [ -n "${CLAUDE_PROMPT:-}" ]; then
        info "Running in non-interactive mode. Tailing output..."
        exec docker logs -f "$cid"
    fi

    # Interactive mode: attach a shell
    info "Attaching shell — exit to detach (container keeps running)"
    info "Reattach later: ./plugins/claude-multiagent/docker/launch.sh --attach"
    echo ""
    exec docker exec -it "$cid" /bin/zsh -l
}

# ── Main ──────────────────────────────────────────────────────

main() {
    parse_args "$@"
    check_prerequisites
    ensure_gh_auth

    if [ "$DELETE_MODE" = "true" ]; then
        check_existing_containers "delete"
        exit 0
    fi

    if [ "$ATTACH_MODE" = "true" ]; then
        check_existing_containers
        exit 0
    fi

    maybe_attach_existing_containers
    select_repo
    ensure_api_key
    if [ -z "${GH_TOKEN:-}" ]; then
        [ "$GH_AVAILABLE" = "true" ] || die "GH_TOKEN is required when gh is unavailable."
        GH_TOKEN=$(gh auth token)
    fi
    if [ "$FORCE_REBUILD" != "true" ]; then
        check_image_freshness
    fi
    build_image "$FORCE_REBUILD"
    launch_container
}

main "$@"
