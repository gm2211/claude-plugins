#!/usr/bin/env bash
# prepare-agent.sh — Prepare a sub-agent: assign tickets and create its worktree.
#
# Marks each ticket in_progress with the given assignee, then calls
# worktree-setup.sh on the first ticket to create (or reuse) a git worktree.
# Prints machine-readable variable assignments to stdout for use with eval.
#
# Usage:
#   eval "$("${CLAUDE_PLUGIN_ROOT}/scripts/prepare-agent.sh" \
#     --name worker-foo \
#     --tickets plug-44,plug-45 \
#     --epic my-epic)"
#
# Options:
#   --name <agent-name>        (required) Agent name; used for assignee and worktree naming
#   --tickets <id1,id2,...>    (required) Comma-separated bead ticket IDs
#   --epic <epic-id>           (optional) Epic bead ID passed to worktree-setup.sh
#   -h, --help                 Show this help message
#
# Output (stdout, machine-readable — safe to eval):
#   WORKTREE_PATH=/absolute/path/to/worktree
#   WORKTREE_BRANCH=branch-name
#   AGENT_NAME=worker-foo
#   AGENT_TICKETS=plug-44,plug-45
#
# Exit codes:
#   0 — success
#   1 — usage / argument error
#   2 — worktree creation failed

# NOTE: We do NOT use set -euo pipefail at the top level because individual
# ticket update failures should be non-fatal (warn and continue). Instead we
# handle errors explicitly where needed.
set -uo pipefail

###############################################################################
# Helpers — all messages go to stderr so they don't pollute the eval output
###############################################################################

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "INFO: $*" >&2; }

usage() {
  cat >&2 <<'USAGE'
Usage: prepare-agent.sh --name <agent-name> --tickets <id1,id2,...> [--epic <epic-id>]

Assigns tickets to an agent and creates its git worktree.

Options:
  --name <agent-name>     (required) Agent name used for ticket assignment
  --tickets <id1,id2,...> (required) Comma-separated bead ticket IDs
  --epic <epic-id>        (optional) Epic bead ID for worktree hierarchy
  -h, --help              Show this help message

Output (stdout, eval-safe):
  WORKTREE_PATH=...
  WORKTREE_BRANCH=...
  AGENT_NAME=...
  AGENT_TICKETS=...
USAGE
  exit 1
}

###############################################################################
# Locate this script's directory so we can call sibling scripts reliably
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Argument Parsing
###############################################################################

AGENT_NAME=""
AGENT_TICKETS=""
EPIC_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      [ $# -lt 2 ] && die "--name requires an argument"
      AGENT_NAME="$2"
      shift 2
      ;;
    --name=*)
      AGENT_NAME="${1#--name=}"
      shift
      ;;
    --tickets)
      [ $# -lt 2 ] && die "--tickets requires an argument"
      AGENT_TICKETS="$2"
      shift 2
      ;;
    --tickets=*)
      AGENT_TICKETS="${1#--tickets=}"
      shift
      ;;
    --epic)
      [ $# -lt 2 ] && die "--epic requires an argument"
      EPIC_ID="$2"
      shift 2
      ;;
    --epic=*)
      EPIC_ID="${1#--epic=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      die "Unexpected positional argument: $1"
      ;;
  esac
done

###############################################################################
# Validate required inputs
###############################################################################

[ -z "$AGENT_NAME" ]    && die "--name is required"
[ -z "$AGENT_TICKETS" ] && die "--tickets is required"

###############################################################################
# Check bd availability
###############################################################################

BD="$(command -v bd 2>/dev/null)" || die "bd command not found in PATH. Install beads first."

###############################################################################
# Update each ticket: status=in_progress, assignee=<agent-name>
###############################################################################

info "Assigning tickets to agent '$AGENT_NAME': $AGENT_TICKETS"

# Split comma-separated list into an array
IFS=',' read -ra TICKET_ARRAY <<< "$AGENT_TICKETS"

for ticket in "${TICKET_ARRAY[@]}"; do
  # Trim any surrounding whitespace
  ticket="$(echo "$ticket" | tr -d '[:space:]')"
  [ -z "$ticket" ] && continue

  info "Updating ticket $ticket → status=in_progress, assignee=$AGENT_NAME"
  if ! "$BD" update "$ticket" --status=in_progress --assignee="$AGENT_NAME" >&2; then
    warn "Failed to update ticket $ticket (continuing)"
  fi
done

###############################################################################
# Determine the primary ticket (first one) for worktree creation
###############################################################################

PRIMARY_TICKET="${TICKET_ARRAY[0]}"
PRIMARY_TICKET="$(echo "$PRIMARY_TICKET" | tr -d '[:space:]')"

[ -z "$PRIMARY_TICKET" ] && die "Could not determine primary ticket from --tickets value: $AGENT_TICKETS"

info "Creating worktree for primary ticket: $PRIMARY_TICKET"

###############################################################################
# Call worktree-setup.sh and capture its eval-safe output
###############################################################################

WORKTREE_SETUP="${SCRIPT_DIR}/worktree-setup.sh"
[ -x "$WORKTREE_SETUP" ] || die "worktree-setup.sh not found or not executable: $WORKTREE_SETUP"

# Build the worktree-setup.sh command arguments
SETUP_ARGS=("$PRIMARY_TICKET")

# worktree-setup.sh does not currently accept --epic directly, but we can pass
# --repo-root if needed. For now, just pass the ticket ID.
# (The epic is used by worktree-setup.sh internally via bd refs/list.)

# Run worktree-setup.sh once:
#   - stdout (the eval-safe VAR=value lines) is captured into WORKTREE_OUTPUT
#   - stderr (INFO/WARNING/ERROR messages) passes through to our stderr so the
#     caller can see progress messages without polluting the eval output
#
# The default $() behaviour already achieves this: stderr inherits our fd 2,
# only stdout is captured.
WORKTREE_OUTPUT=""
if ! WORKTREE_OUTPUT="$("$WORKTREE_SETUP" "${SETUP_ARGS[@]}")"; then
  die "worktree-setup.sh failed for ticket $PRIMARY_TICKET"
fi

###############################################################################
# Parse the worktree output to extract WORKTREE_PATH and WORKTREE_BRANCH
###############################################################################

WORKTREE_PATH=""
WORKTREE_BRANCH=""

while IFS= read -r line; do
  case "$line" in
    WORKTREE_PATH=*)  WORKTREE_PATH="${line#WORKTREE_PATH=}" ;;
    WORKTREE_BRANCH=*) WORKTREE_BRANCH="${line#WORKTREE_BRANCH=}" ;;
  esac
done <<< "$WORKTREE_OUTPUT"

[ -z "$WORKTREE_PATH" ]   && die "worktree-setup.sh did not output WORKTREE_PATH"
[ -z "$WORKTREE_BRANCH" ] && die "worktree-setup.sh did not output WORKTREE_BRANCH"

info "Worktree ready: $WORKTREE_PATH (branch: $WORKTREE_BRANCH)"

###############################################################################
# Print eval-safe variable assignments to stdout
###############################################################################

printf 'WORKTREE_PATH=%s\n'   "$WORKTREE_PATH"
printf 'WORKTREE_BRANCH=%s\n' "$WORKTREE_BRANCH"
printf 'AGENT_NAME=%s\n'      "$AGENT_NAME"
printf 'AGENT_TICKETS=%s\n'   "$AGENT_TICKETS"

exit 0
