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

usage() {
    cat <<'USAGE'
Usage: launch.sh [OPTIONS] [REPO]

Launch a sandboxed Claude Code instance in Docker for a specific repo.

Options:
  --rebuild     Force rebuild the Docker image
  --attach      List running containers and attach to one
  --no-push     Autonomous mode: commits local only, no git push
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

    if ! command -v gh &>/dev/null; then
        die "GitHub CLI (gh) is not installed.\n  macOS: brew install gh\n  Linux: https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
    fi
}

# ── Step 2: GitHub Authentication ─────────────────────────────

ensure_gh_auth() {
    if gh auth status &>/dev/null; then
        success "GitHub CLI authenticated"
        return 0
    fi

    info "GitHub authentication required. A browser will open for you to authorize."
    info "Press Enter to continue..."
    read -r

    gh auth login --web --git-protocol https --scopes repo

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

check_existing_containers() {
    if [ "$ATTACH_MODE" = "true" ]; then
        if list_containers; then
            echo ""
            printf "  Enter container number to attach: "
            read -r choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#CONTAINER_IDS[@]}" ]; then
                attach_to_container "${CONTAINER_IDS[$((choice-1))]}"
            else
                die "Invalid selection: $choice"
            fi
        else
            die "No containers found. Launch a new one without --attach."
        fi
    fi

    # Non-attach mode: if containers exist, offer to attach or start new
    if list_containers 2>/dev/null; then
        echo ""
        printf "  Attach to existing (enter number) or start new (n): "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#CONTAINER_IDS[@]}" ]; then
            attach_to_container "${CONTAINER_IDS[$((choice-1))]}"
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

    # Fetch recent repos
    local repos
    repos=$(gh repo list --limit 15 --json nameWithOwner -q '.[].nameWithOwner' 2>/dev/null || true)

    if [ -n "$repos" ]; then
        local i=1
        local repo_array=()
        while IFS= read -r repo; do
            repo_array+=("$repo")
            printf "  %2d) %s\n" "$i" "$repo"
            ((i++))
        done <<< "$repos"
        echo ""
        printf "  Enter number, or type owner/repo: "
        read -r selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#repo_array[@]}" ]; then
            REPO="${repo_array[$((selection-1))]}"
        elif [[ "$selection" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
            REPO="$selection"
        else
            die "Invalid selection: $selection"
        fi
    else
        printf "  Enter repository (owner/repo): "
        read -r REPO
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
    container_name="claude-$(echo "$REPO" | tr '/' '-' | tr '.' '-')"

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

        # Check if setup is done (sleep infinity is running = repo cloned, ready)
        if docker exec "$cid" test -d /home/claude/repo 2>/dev/null; then
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
    GH_TOKEN=$(gh auth token)
    build_image "$FORCE_REBUILD"
    launch_container
}

main "$@"
