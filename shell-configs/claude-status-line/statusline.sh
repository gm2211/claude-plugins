#!/bin/bash
input=$(cat)

# Extract fields from Claude's JSON
MODEL=$(echo "$input" | jq -r '.model.display_name // .model.id // "?"')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DIR=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
ADDED=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
REMOVED=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Sandbox mode — read from input JSON first, fall back to settings.json
SANDBOX_ENABLED=$(echo "$input" | jq -r '.sandbox.enabled // empty' 2>/dev/null)
SANDBOX_MODE=$(echo "$input" | jq -r '.sandbox.mode // empty' 2>/dev/null)
if [ -z "$SANDBOX_ENABLED" ]; then
    SETTINGS="$HOME/.claude/settings.json"
    if [ -f "$SETTINGS" ]; then
        SANDBOX_ENABLED=$(jq -r '.sandbox.enabled // empty' "$SETTINGS" 2>/dev/null)
        SANDBOX_MODE=$(jq -r '.sandbox.mode // empty' "$SETTINGS" 2>/dev/null)
    fi
fi

# Current time
TIME=$(date '+%H:%M')

# Git info (run from the workspace dir)
GIT_INFO=""
if [ -n "$DIR" ] && cd "$DIR" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
    BRANCH=$(git branch --show-current 2>/dev/null)
    # Detect worktree and get repo name
    WT=""
    GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
    COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null)
    if [ -n "$COMMON_DIR" ] && [ "$GIT_DIR" != "$COMMON_DIR" ]; then
        WT=" wt"
        # In a worktree, derive repo name from the main repo's .git dir
        REPO=$(basename "$(dirname "$(cd "$DIR" && cd "$COMMON_DIR" && pwd)")" 2>/dev/null)
    else
        REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
    fi
    # Files changed (unique count from porcelain status)
    TOTAL_CHANGED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    # Git additions/deletions from diff
    GIT_ADDS=$(git diff --numstat HEAD 2>/dev/null | awk '{s+=$1} END {print s+0}')
    GIT_DELS=$(git diff --numstat HEAD 2>/dev/null | awk '{s+=$2} END {print s+0}')
    GIT_INFO=" \033[90m|\033[0m \033[36m${REPO}\033[0m:\033[33m${BRANCH}${WT}\033[0m \033[90m${TOTAL_CHANGED}f\033[0m \033[32m+${GIT_ADDS}\033[0m \033[31m-${GIT_DELS}\033[0m"
fi

# Context bar — thin 20-char bar
BAR_LEN=20
if [ "$PCT" -ge 90 ]; then
    BAR_COLOR='\033[31m'  # red
elif [ "$PCT" -ge 70 ]; then
    BAR_COLOR='\033[33m'  # yellow
else
    BAR_COLOR='\033[32m'  # green
fi
FILLED=$((PCT * BAR_LEN / 100))
[ "$FILLED" -gt "$BAR_LEN" ] && FILLED=$BAR_LEN
EMPTY=$((BAR_LEN - FILLED))
BAR="${BAR_COLOR}$(printf '%*s' "$FILLED" '' | tr ' ' '▮')\033[90m$(printf '%*s' "$EMPTY" '' | tr ' ' '─')\033[0m"

# Cost
COST_FMT=$(printf '$%.2f' "$COST")

# Session lines added/removed
SESSION_CHANGES=""
if [ "$ADDED" -gt 0 ] || [ "$REMOVED" -gt 0 ]; then
    SESSION_CHANGES=" \033[32m+${ADDED}\033[0m\033[31m-${REMOVED}\033[0m"
fi

# Sandbox indicator
SANDBOX_STR=""
if [ "$SANDBOX_ENABLED" = "true" ]; then
    # Friendly label for known mode values
    case "$SANDBOX_MODE" in
        auto-allow)  MODE_LABEL="auto" ;;
        manual)      MODE_LABEL="manual" ;;
        *)           MODE_LABEL="${SANDBOX_MODE:-on}" ;;
    esac
    SANDBOX_STR=" \033[90m|\033[0m \033[35msandbox:${MODE_LABEL}\033[0m"
elif [ "$SANDBOX_ENABLED" = "false" ]; then
    SANDBOX_STR=" \033[90m|\033[0m \033[90msandbox:off\033[0m"
fi

# Current working directory (full path, with ~ for home directory)
DIR_DISPLAY=""
if [ -n "$DIR" ]; then
    DIR_SHORT=$(echo "$DIR" | sed "s|^$HOME|~|")
    DIR_DISPLAY=" \033[90m|\033[0m \033[34m${DIR_SHORT}\033[0m"
fi

# Output single line
echo -e "\033[90m${TIME}\033[0m \033[1m${MODEL}\033[0m${SANDBOX_STR}${DIR_DISPLAY} \033[90m|\033[0m ${BAR} ${PCT}%${GIT_INFO} \033[90m|\033[0m \033[33m${COST_FMT}\033[0m"
