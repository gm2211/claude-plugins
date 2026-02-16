#!/bin/bash
# Interactive TUI for browsing beads tickets
# Uses alternate screen buffer, keyboard navigation, colored status indicators

# Force UTF-8 for Unicode characters
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

BD="${HOME}/.local/bin/bd"

# --- ANSI colors ---
RST=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
REV=$'\033[7m'        # reverse video for selection highlight
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
CYAN=$'\033[36m'
GRAY=$'\033[90m'

# --- State ---
MODE="list"           # list | detail
CURSOR=0              # selected row index
SCROLL=0              # first visible row index
TICKET_IDS=()         # parallel arrays from parsed bd output
TICKET_LINES=()       # display lines (colorized, prefix-stripped)
TICKET_RAW=()         # raw lines for parsing
DETAIL_TEXT=""         # cached detail output
NEED_REDRAW=1         # flag to trigger redraw
TERM_ROWS=0
TERM_COLS=0
HEADER_LINES=3        # lines reserved for header
FOOTER_LINES=2        # lines reserved for footer

# --- Terminal helpers ---

get_term_size() {
  TERM_ROWS=$(tput lines 2>/dev/null || echo 24)
  TERM_COLS=$(tput cols 2>/dev/null || echo 80)
}

enter_tui() {
  tput smcup 2>/dev/null        # alternate screen buffer
  tput civis 2>/dev/null        # hide cursor
  stty -echo -icanon 2>/dev/null
  printf '\033[?25l'            # belt-and-suspenders cursor hide
}

exit_tui() {
  tput cnorm 2>/dev/null        # show cursor
  tput rmcup 2>/dev/null        # restore main screen
  stty echo icanon 2>/dev/null
  printf '\033[?25h'
  # kill background jobs
  kill $(jobs -p) 2>/dev/null
  wait 2>/dev/null
}

trap exit_tui EXIT
trap 'get_term_size; NEED_REDRAW=1' WINCH

# --- Data loading ---

load_tickets() {
  local raw_output
  if ! command -v "$BD" &>/dev/null && ! command -v bd &>/dev/null; then
    TICKET_IDS=()
    TICKET_LINES=("  bd command not found." "  Install beads to use this panel.")
    TICKET_RAW=()
    return
  fi
  if [ ! -d ".beads" ]; then
    TICKET_IDS=()
    TICKET_LINES=("  No beads initialized in this repo." "  Run 'bd init' to get started.")
    TICKET_RAW=()
    return
  fi

  raw_output=$("$BD" list --pretty 2>/dev/null)
  if [[ $? -ne 0 ]] || [[ -z "$raw_output" ]]; then
    TICKET_IDS=()
    TICKET_LINES=("  (bd list failed or returned empty)")
    TICKET_RAW=()
    return
  fi

  # Detect common prefix from first ticket ID (e.g. "claude-plugins-")
  local prefix=""
  local first_id
  first_id=$(echo "$raw_output" | head -1 | sed -E 's/^[^ ]+ //' | awk '{print $1}')
  if [[ "$first_id" =~ ^(.+-)[a-z0-9]+$ ]]; then
    prefix="${BASH_REMATCH[1]}"
  fi

  TICKET_IDS=()
  TICKET_LINES=()
  TICKET_RAW=()

  local summary_line=""
  while IFS= read -r line; do
    # Skip empty lines and separator lines
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^-+$ ]] && continue
    # Capture the summary/total line
    if [[ "$line" =~ ^Total: ]] || [[ "$line" =~ ^Status: ]]; then
      if [[ "$line" =~ ^Total: ]]; then
        summary_line="$line"
      fi
      continue
    fi

    # Parse ticket lines: <status_symbol> <full-id> <priority_symbol> <priority> <title...>
    # The status symbol is one of: ○ ◐ ● ✓ ❄
    # Bash ${var:offset:len} counts characters not bytes, so :0:1 gets the symbol
    local status_char full_id rest
    status_char="${line:0:1}"
    # After "symbol + space" the rest starts at character index 2
    local after_sym="${line:2}"
    full_id=$(echo "$after_sym" | awk '{print $1}')
    rest="${after_sym#"$full_id" }"

    # Strip prefix from display ID
    local short_id="$full_id"
    if [[ -n "$prefix" ]]; then
      short_id="${full_id#"$prefix"}"
    fi

    # Colorize status symbol
    local colored_sym
    case "$status_char" in
      "○")  colored_sym="${GREEN}○${RST}" ;;   # open
      "◐")  colored_sym="${YELLOW}◐${RST}" ;;  # in_progress
      "●")  colored_sym="${RED}●${RST}" ;;      # blocked
      "✓")  colored_sym="${GRAY}✓${RST}" ;;     # closed
      "❄")  colored_sym="${CYAN}❄${RST}" ;;     # deferred
      *)    colored_sym="${status_char}" ;;
    esac

    # Rebuild the display line with short ID and colored status
    # Format: <colored_sym> <short_id>  <rest>
    local display_line
    display_line=$(printf "  %s %-4s %s" "$colored_sym" "$short_id" "$rest")

    TICKET_IDS+=("$full_id")
    TICKET_LINES+=("$display_line")
    TICKET_RAW+=("$line")
  done <<< "$raw_output"

  # Store summary for header
  SUMMARY_LINE="${summary_line}"

  # Clamp cursor
  local count=${#TICKET_IDS[@]}
  if (( count == 0 )); then
    CURSOR=0
  elif (( CURSOR >= count )); then
    CURSOR=$(( count - 1 ))
  fi
}

# --- Rendering ---

render_list() {
  local buf=""
  local count=${#TICKET_IDS[@]}
  get_term_size

  # Parse summary for header
  local header_info=""
  if [[ -n "$SUMMARY_LINE" ]]; then
    # Extract counts from "Total: 7 issues (5 open, 2 in progress)"
    local counts
    counts=$(echo "$SUMMARY_LINE" | sed -E 's/^Total: [0-9]+ issues \((.+)\)/\1/')
    header_info="$counts"
  fi

  # Header
  buf+=$(printf '\033[H')  # move to top-left
  buf+="${BOLD}Beads${RST}"
  if [[ -n "$header_info" ]]; then
    buf+="  ${DIM}(${header_info})${RST}"
  fi
  # Right-align timestamp
  local ts
  ts=$(date '+%H:%M:%S')
  local header_text="Beads  (${header_info})"
  local header_plain_len=${#header_text}
  local ts_col=$(( TERM_COLS - 10 ))
  if (( ts_col > header_plain_len + 2 )); then
    buf+=$(printf '\033[1;%dH' "$ts_col")
    buf+="${DIM}@ ${ts}${RST}"
  fi
  buf+=$'\n\n'

  # Visible area for tickets
  local visible_rows=$(( TERM_ROWS - HEADER_LINES - FOOTER_LINES ))
  if (( visible_rows < 1 )); then
    visible_rows=1
  fi

  # Adjust scroll to keep cursor visible
  if (( CURSOR < SCROLL )); then
    SCROLL=$CURSOR
  elif (( CURSOR >= SCROLL + visible_rows )); then
    SCROLL=$(( CURSOR - visible_rows + 1 ))
  fi

  if (( count == 0 )); then
    # No tickets — show placeholder lines
    for line in "${TICKET_LINES[@]}"; do
      buf+="${line}"$'\n'
    done
  else
    local end=$(( SCROLL + visible_rows ))
    if (( end > count )); then
      end=$count
    fi
    for (( i = SCROLL; i < end; i++ )); do
      if (( i == CURSOR )); then
        buf+="${REV}${TICKET_LINES[$i]}${RST}"
      else
        buf+="  ${TICKET_LINES[$i]:2}"  # keep indent but no reverse
      fi
      # Clear to end of line to avoid artifacts
      buf+=$'\033[K\n'
    done
    # Fill remaining visible rows with blank lines
    local rendered=$(( end - SCROLL ))
    for (( j = rendered; j < visible_rows; j++ )); do
      buf+=$'\033[K\n'
    done
  fi

  # Footer — pinned to bottom
  buf+=$(printf '\033[%d;1H' "$(( TERM_ROWS - 1 ))")
  buf+=$'\033[K'
  buf+="${DIM}↑↓/jk navigate  ⏎ details  r refresh  q quit${RST}"

  # Flush buffer all at once
  printf '%s' "$buf"
}

render_detail() {
  local buf=""
  get_term_size

  buf+=$(printf '\033[H')  # move to top-left

  # Render detail text with line limit
  local line_count=0
  local max_lines=$(( TERM_ROWS - 3 ))
  while IFS= read -r line; do
    if (( line_count >= max_lines )); then
      break
    fi
    buf+="${line}"$'\033[K\n'
    (( line_count++ ))
  done <<< "$DETAIL_TEXT"

  # Clear remaining lines
  for (( i = line_count; i < max_lines; i++ )); do
    buf+=$'\033[K\n'
  done

  # Footer
  buf+=$(printf '\033[%d;1H' "$(( TERM_ROWS - 1 ))")
  buf+=$'\033[K'
  buf+="${DIM}⏎/q back${RST}"

  printf '%s' "$buf"
}

render() {
  case "$MODE" in
    list)   render_list ;;
    detail) render_detail ;;
  esac
  NEED_REDRAW=0
}

# --- Detail view ---

show_detail() {
  local idx=$1
  if (( idx < 0 || idx >= ${#TICKET_IDS[@]} )); then
    return
  fi
  local tid="${TICKET_IDS[$idx]}"
  local raw
  raw=$("$BD" show "$tid" 2>/dev/null)

  # Colorize the status symbol on the first line only
  local first_line rest_lines
  first_line="${raw%%$'\n'*}"
  rest_lines="${raw#*$'\n'}"
  local first_char="${first_line:0:1}"
  local colored=""
  case "$first_char" in
    "○") colored="${GREEN}○${RST}${first_line:1}" ;;
    "◐") colored="${YELLOW}◐${RST}${first_line:1}" ;;
    "●") colored="${RED}●${RST}${first_line:1}" ;;
    "✓") colored="${GRAY}✓${RST}${first_line:1}" ;;
    "❄") colored="${CYAN}❄${RST}${first_line:1}" ;;
    *)   colored="$first_line" ;;
  esac

  if [[ "$raw" == *$'\n'* ]]; then
    DETAIL_TEXT="${colored}"$'\n'"${rest_lines}"
  else
    DETAIL_TEXT="${colored}"
  fi

  MODE="detail"
  NEED_REDRAW=1
}

# --- Background refresh ---

start_bg_refresh() {
  (
    if command -v fswatch &>/dev/null && [ -d ".beads" ]; then
      fswatch --latency 1 --one-per-batch \
        ".beads/issues.jsonl" ".beads/beads.db-wal" 2>/dev/null \
      | while read -r _; do
        # Signal main loop to refresh (only in list mode)
        kill -USR1 $$ 2>/dev/null
      done
    fi
    # Fallback: periodic signal
    while true; do
      sleep 5
      kill -USR1 $$ 2>/dev/null
    done
  ) &
}

BG_REFRESH=0
trap 'BG_REFRESH=1' USR1

# --- Main ---

get_term_size
enter_tui
load_tickets
render

start_bg_refresh

while true; do
  # Check for background refresh request
  if (( BG_REFRESH )); then
    BG_REFRESH=0
    if [[ "$MODE" == "list" ]]; then
      load_tickets
      NEED_REDRAW=1
    fi
  fi

  if (( NEED_REDRAW )); then
    render
  fi

  # Read a single character with timeout (allows checking BG_REFRESH)
  if ! read -rsn1 -t 0.2 key 2>/dev/null; then
    # Timeout — loop to check BG_REFRESH
    continue
  fi

  # Handle escape sequences (arrows)
  if [[ "$key" == $'\x1b' ]]; then
    read -rsn1 -t 0.05 seq1 2>/dev/null
    if [[ "$seq1" == "[" ]]; then
      read -rsn1 -t 0.05 seq2 2>/dev/null
      case "$seq2" in
        A) key="UP" ;;
        B) key="DOWN" ;;
        *) key="" ;;
      esac
    elif [[ -z "$seq1" ]]; then
      # Bare Escape
      key="ESC"
    else
      key=""
    fi
  fi

  local_count=${#TICKET_IDS[@]}

  case "$MODE" in
    list)
      case "$key" in
        k|UP)
          if (( CURSOR > 0 )); then
            (( CURSOR-- ))
            NEED_REDRAW=1
          fi
          ;;
        j|DOWN)
          if (( CURSOR < local_count - 1 )); then
            (( CURSOR++ ))
            NEED_REDRAW=1
          fi
          ;;
        "")  # Enter key (read -rsn1 yields empty string for Enter)
          if (( local_count > 0 )); then
            show_detail "$CURSOR"
          fi
          ;;
        r)
          load_tickets
          NEED_REDRAW=1
          ;;
        q|ESC)
          exit 0
          ;;
      esac
      ;;
    detail)
      case "$key" in
        q|ESC|"")  # q, Escape, or Enter goes back
          MODE="list"
          NEED_REDRAW=1
          ;;
      esac
      ;;
  esac
done
