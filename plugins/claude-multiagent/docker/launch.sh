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
NO_PUSH="false"
GH_AVAILABLE="false"
PERSIST_REPO="false"

usage() {
    cat <<'USAGE'
Usage: launch.sh [OPTIONS] [REPO]

Launch a sandboxed Claude Code instance in Docker for a specific repo.

Options:
  --rebuild     Force rebuild the Docker image
  --attach      List running containers and attach to one
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

CONTAINER_IDS=()

list_containers() {
    # Find ALL containers (running + stopped) from the claude-multiagent image
    local containers
    containers=$(docker ps -a --filter "ancestor=$IMAGE_NAME" --format '{{.ID}}' 2>/dev/null)

    if [ -z "$containers" ]; then
        return 1
    fi

    local i=1
    CONTAINER_IDS=()
    CONTAINER_STATES=()
    echo ""
    info "Existing claude-multiagent containers:"
    echo ""
    printf "  %3s  %-20s  %-30s  %s\n" "#" "NAME" "REPO" "STATUS"
    printf "  %3s  %-20s  %-30s  %s\n" "---" "--------------------" "------------------------------" "--------"

    while IFS= read -r cid; do
        CONTAINER_IDS+=("$cid")
        local repo name status state
        repo=$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^REPO=' | cut -d= -f2-)
        name=$(docker inspect "$cid" --format '{{.Name}}' | sed 's|^/||')
        status=$(docker ps -a --filter "id=$cid" --format '{{.Status}}')
        state=$(docker inspect "$cid" --format '{{.State.Status}}')
        CONTAINER_STATES+=("$state")
        printf "  %3d  %-20s  %-30s  %s\n" "$i" "${name:-$cid}" "${repo:-unknown}" "$status"
        ((i++))
    done <<< "$containers"

    return 0
}

attach_to_container() {
    local cid="$1"
    local state
    state=$(docker inspect "$cid" --format '{{.State.Status}}' 2>/dev/null)

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

repo_volume_name() {
    local slug
    slug=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g')
    printf 'claude-repo-%s' "$slug"
}

# Build fzf display lines from the current CONTAINER_IDS arrays.
# Each line: "NAME  REPO  STATUS"
_container_fzf_lines() {
    local i=0
    while [ "$i" -lt "${#CONTAINER_IDS[@]}" ]; do
        local cid="${CONTAINER_IDS[$i]}"
        local repo name status
        repo=$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^REPO=' | cut -d= -f2-)
        name=$(docker inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
        status=$(docker ps -a --filter "id=$cid" --format '{{.Status}}' 2>/dev/null)
        printf "%-20s  %-30s  %s\n" "${name:-$cid}" "${repo:-unknown}" "${status:-unknown}"
        ((i++))
    done
}

# Given a fzf-selected line, return the 0-based index of the matching container.
_container_index_from_line() {
    local selected="$1"
    local selected_name
    selected_name=$(printf '%s' "$selected" | awk '{print $1}')
    local i=0
    while [ "$i" -lt "${#CONTAINER_IDS[@]}" ]; do
        local cid="${CONTAINER_IDS[$i]}"
        local name
        name=$(docker inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
        if [ "${name:-$cid}" = "$selected_name" ]; then
            echo "$i"
            return 0
        fi
        ((i++))
    done
    return 1
}

check_existing_containers() {
    if [ "$ATTACH_MODE" = "true" ]; then
        if list_containers; then
            echo ""
            local choice=""
            if _tty_available && command -v fzf >/dev/null 2>&1; then
                # fzf mode
                local selected
                selected=$(_container_fzf_lines | fzf --height=~50% --reverse \
                    --prompt="Select container to attach: " \
                    --header="Arrow keys to navigate, Enter to select, Esc to cancel" \
                    2>/dev/null </dev/tty)
                local fzf_exit=$?
                if [ "$fzf_exit" -ne 0 ] || [ -z "$selected" ]; then
                    die "No container selected."
                fi
                local idx
                idx=$(_container_index_from_line "$selected") || die "Could not resolve selected container."
                attach_to_container "${CONTAINER_IDS[$idx]}"
            elif _tty_available; then
                # Numbered list fallback
                printf "  Enter container number to attach: "
                read -r choice </dev/tty
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#CONTAINER_IDS[@]}" ]; then
                    attach_to_container "${CONTAINER_IDS[$((choice-1))]}"
                else
                    die "Invalid selection: $choice"
                fi
            else
                error "No TTY available for interactive selection."
                die "Run launch.sh --attach in an interactive terminal."
            fi
        else
            die "No containers found. Launch a new one without --attach."
        fi
    fi

    # Non-attach mode: if containers exist, offer to attach or start new
    if list_containers 2>/dev/null; then
        echo ""
        if _tty_available && command -v fzf >/dev/null 2>&1; then
            # fzf mode — Esc means start new
            local selected
            selected=$(_container_fzf_lines | fzf --height=~50% --reverse \
                --prompt="Attach to existing or Esc for new: " \
                --header="Arrow keys to navigate, Enter to select, Esc to start new" \
                2>/dev/null </dev/tty)
            local fzf_exit=$?
            if [ "$fzf_exit" -eq 0 ] && [ -n "$selected" ]; then
                local idx
                idx=$(_container_index_from_line "$selected") || die "Could not resolve selected container."
                attach_to_container "${CONTAINER_IDS[$idx]}"
            fi
            # Esc or empty → fall through to start a new container
        elif _tty_available; then
            # Numbered list fallback
            local choice=""
            printf "  Attach to existing (enter number) or start new (n): "
            read -r choice </dev/tty
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#CONTAINER_IDS[@]}" ]; then
                attach_to_container "${CONTAINER_IDS[$((choice-1))]}"
            fi
        else
            # No TTY — list containers and fall through to start new
            warn "No TTY available; skipping container selection. Starting a new container."
        fi
        echo ""
    fi
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

        if _tty_available && command -v fzf >/dev/null 2>&1; then
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
            # Numbered list fallback
            local i=1
            for repo in "${repo_array[@]}"; do
                printf "  %2d) %s\n" "$i" "$repo"
                ((i++))
            done
            echo ""
            printf "  Enter number, or type owner/repo: "
            read -r selection </dev/tty

            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#repo_array[@]}" ]; then
                REPO="${repo_array[$((selection-1))]}"
            elif [[ "$selection" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
                REPO="$selection"
            else
                die "Invalid selection: $selection"
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

# ── Step 6: Build Image ──────────────────────────────────────

build_image() {
    local force="${1:-false}"

    if [ "$force" = "true" ] || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        info "Building Docker image..."
        docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$REPO_ROOT"
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

    # Remove stopped container with same name if it exists
    docker rm "$container_name" 2>/dev/null || true

    local docker_args=(
        "run" "-d"
        "--name" "$container_name"
        "-e" "GH_TOKEN=$GH_TOKEN"
        "-e" "REPO=$REPO"
        "--memory=4g"
        "--cpus=2"
        "--tmpfs" "/tmp:rw,noexec,nosuid,size=512m"
    )

    # Optional env vars
    [ -n "${ANTHROPIC_API_KEY:-}" ] && docker_args+=("-e" "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
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

    # Check for existing containers before repo selection
    check_existing_containers

    select_repo
    ensure_api_key
    if [ -z "${GH_TOKEN:-}" ]; then
        [ "$GH_AVAILABLE" = "true" ] || die "GH_TOKEN is required when gh is unavailable."
        GH_TOKEN=$(gh auth token)
    fi
    build_image "$FORCE_REBUILD"
    launch_container
}

main "$@"
