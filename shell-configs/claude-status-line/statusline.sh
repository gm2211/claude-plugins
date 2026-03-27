#!/bin/bash
if ! command -v jq &>/dev/null; then
  echo "statusline: jq not found"
  exit 0
fi
input=$(cat)

# Extract fields from Claude's JSON
MODEL=$(echo "$input" | jq -r '.model.display_name // .model.id // "?"')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DIR=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
ADDED=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
REMOVED=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Sandbox mode — read from input JSON first, then Claude user/local settings
SANDBOX_ENABLED=$(echo "$input" | jq -r '.sandbox.enabled // empty' 2>/dev/null)
SANDBOX_MODE=$(echo "$input" | jq -r '.sandbox.mode // empty' 2>/dev/null)
if [ -z "$SANDBOX_ENABLED" ]; then
    for SETTINGS in "$HOME/.claude/settings.local.json" "$HOME/.claude/settings.json"; do
        if [ -f "$SETTINGS" ]; then
            SANDBOX_ENABLED=$(jq -r '.sandbox.enabled // empty' "$SETTINGS" 2>/dev/null)
            SANDBOX_MODE=$(jq -r '.sandbox.mode // empty' "$SETTINGS" 2>/dev/null)
        fi
        [ -n "$SANDBOX_ENABLED" ] && break
    done
fi

# Current time
TIME=$(date '+%H:%M')

# Git info (run from the workspace dir)
GIT_INFO=""
REPO=""
BRANCH=""
WT=""
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

# Terminal width detection (needed early for bar scaling)
TERM_COLS="${COLUMNS:-0}"
if [ "$TERM_COLS" -eq 0 ]; then
    TERM_COLS=$(tput cols 2>/dev/null || echo 120)
fi

# Context bar — scales with terminal width
if [ "$TERM_COLS" -ge 100 ]; then
    BAR_LEN=20
elif [ "$TERM_COLS" -ge 60 ]; then
    BAR_LEN=10
else
    BAR_LEN=5
fi
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
BAR="${BAR_COLOR}$(printf '%*s' "$FILLED" '' | tr ' ' '=')\033[90m$(printf '%*s' "$EMPTY" '' | tr ' ' '-')\033[0m"

# Cost
COST_FMT=$(printf '$%.2f' "$COST")

# Session lines added/removed
SESSION_CHANGES=""
if [ "$ADDED" -gt 0 ] || [ "$REMOVED" -gt 0 ]; then
    SESSION_CHANGES=" \033[32m+${ADDED}\033[0m\033[31m-${REMOVED}\033[0m"
fi

# Sandbox indicator — compact at narrow widths
SANDBOX_STR=""
if [ "$SANDBOX_ENABLED" = "true" ]; then
    if [ "$TERM_COLS" -ge 100 ]; then
        case "$SANDBOX_MODE" in
            auto-allow)  MODE_LABEL="sandbox:auto" ;;
            manual)      MODE_LABEL="sandbox:manual" ;;
            *)           MODE_LABEL="sandbox:${SANDBOX_MODE:-on}" ;;
        esac
    else
        case "$SANDBOX_MODE" in
            auto-allow)  MODE_LABEL="sbox:a" ;;
            manual)      MODE_LABEL="sbox:m" ;;
            *)           MODE_LABEL="sbox:${SANDBOX_MODE:-on}" ;;
        esac
    fi
    SANDBOX_STR=" \033[90m|\033[0m \033[35m${MODE_LABEL}\033[0m"
elif [ "$SANDBOX_ENABLED" = "false" ]; then
    if [ "$TERM_COLS" -ge 100 ]; then
        SANDBOX_STR=" \033[90m|\033[0m \033[90msandbox:off\033[0m"
    else
        SANDBOX_STR=" \033[90m|\033[0m \033[90msbox:off\033[0m"
    fi
fi

# Current working directory (full path, with ~ for home directory)
DIR_DISPLAY=""
if [ -n "$DIR" ]; then
    DIR_SHORT=$(echo "$DIR" | sed "s|^$HOME|~|")
    DIR_DISPLAY=" \033[90m|\033[0m \033[34m${DIR_SHORT}\033[0m"
fi

# Strip ANSI escapes to measure visible length of a string
strip_ansi() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'
}
visible_len() {
    str=$(strip_ansi "$1")
    printf '%s' "${#str}"
}

# Build the full line and measure it, then progressively drop sections if too wide
# Cost and context bar are highest priority — they come right after the model name.
# Full line (>=100 cols): TIME MODEL | BAR PCT% | COST | GIT_INFO SANDBOX DIR
# Narrow (<100 cols): TIME MODEL | BAR PCT% | COST | REPO:BRANCH
# Very narrow (<60 cols): MODEL | BAR PCT% | COST

BAR_SECTION="${BAR} ${PCT}%"
CORE="\033[90m|\033[0m ${BAR_SECTION} \033[90m|\033[0m \033[33m${COST_FMT}\033[0m"

build_full()   { echo -e "\033[90m${TIME}\033[0m \033[1m${MODEL}\033[0m ${CORE}${GIT_INFO}${SANDBOX_STR}${DIR_DISPLAY}"; }
build_narrow() {
    GIT_SHORT=""
    if [ -n "$REPO" ]; then
        GIT_SHORT=" \033[90m|\033[0m \033[36m${REPO}\033[0m:\033[33m${BRANCH}${WT}\033[0m"
    fi
    echo -e "\033[90m${TIME}\033[0m \033[1m${MODEL}\033[0m ${CORE}${GIT_SHORT}"
}
build_vnarrow() { echo -e "\033[1m${MODEL}\033[0m ${CORE}"; }

if [ "$TERM_COLS" -ge 100 ]; then
    LINE=$(build_full)
    VIS=$(visible_len "$LINE")
    if [ "$VIS" -le "$TERM_COLS" ]; then
        echo "$LINE"
    else
        echo "$(build_narrow)"
    fi
elif [ "$TERM_COLS" -ge 60 ]; then
    echo "$(build_narrow)"
else
    echo "$(build_vnarrow)"
fi
