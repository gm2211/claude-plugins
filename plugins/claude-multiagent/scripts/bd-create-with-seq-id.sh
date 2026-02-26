#!/usr/bin/env bash
# Wrapper around `bd create` that assigns sequential IDs (<prefix>-17, <prefix>-18, …).
# Reads/increments a counter stored in bd config (custom.issue_counter).
# All arguments are forwarded to `bd create`.
#
# Usage: bd-create-seq.sh --title "Fix bug" --type=bug --priority=1

set -euo pipefail

BD="$(command -v bd)"

# Read current counter (default 0 if unset)
counter=$("$BD" config get custom.issue_counter 2>/dev/null | grep -oE '[0-9]+' || echo 0)
next=$(( counter + 1 ))

# Read repo's configured prefix (default to 'plug' if unset)
prefix=$("$BD" config get issue_prefix 2>/dev/null | grep -oE '[a-zA-Z0-9_-]+' || echo "plug")

# Reserve the counter immediately (atomic: if two scripts race, one gets a
# duplicate --id error from bd and can retry)
"$BD" config set custom.issue_counter "$next" >/dev/null

# Create with explicit sequential ID
"$BD" create --id "${prefix}-${next}" "$@"
