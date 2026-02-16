#!/bin/bash
# Watches agent status files and renders a pretty Unicode table or card layout.
# Reads per-agent files from .agent-status.d/ (preferred) or falls back to
# .agent-status.md for backward compatibility.
# Uses fswatch for efficient event-driven updates, falls back to polling.

# Force UTF-8 for Unicode box-drawing characters
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# Enter alternate screen buffer (like vim/htop); hide cursor; restore on exit
tput smcup 2>/dev/null
trap 'tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; exit' INT TERM EXIT
tput civis 2>/dev/null

STATUS_DIR=".agent-status.d"

elapsed_since() {
  local start="$1"
  if ! [[ "$start" =~ ^[0-9]+$ ]]; then
    printf '%s' "$start"
    return
  fi
  local now diff
  now=$(date +%s)
  diff=$(( now - start ))
  if [ $diff -lt 0 ]; then diff=0; fi
  if [ $diff -lt 60 ]; then
    printf '%ds' "$diff"
  elif [ $diff -lt 3600 ]; then
    printf '%dm %ds' "$(( diff / 60 ))" "$(( diff % 60 ))"
  else
    printf '%dh %dm' "$(( diff / 3600 ))" "$(( (diff % 3600) / 60 ))"
  fi
}

# Format a "Last Action" field: "desc|timestamp" -> "desc (Xm ago)"
format_last_action() {
  local raw="$1"
  if [[ "$raw" == *"|"* ]]; then
    local desc="${raw%|*}"
    local ts="${raw##*|}"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      local ago
      ago=$(elapsed_since "$ts")
      printf '%s (%s ago)' "$desc" "$ago"
    else
      printf '%s' "$desc"
    fi
  else
    printf '%s' "$raw"
  fi
}

# Compute the longest common prefix among a list of strings.
common_prefix() {
  local -a items=("$@")
  [ ${#items[@]} -eq 0 ] && return
  local prefix="${items[0]}"
  for item in "${items[@]:1}"; do
    while [ ${#prefix} -gt 0 ] && [[ "$item" != "${prefix}"* ]]; do
      prefix="${prefix%?}"
    done
    [ ${#prefix} -eq 0 ] && break
  done
  printf '%s' "$prefix"
}

# Parse a legacy status file that may be TSV or Markdown table format.
# Outputs clean TSV lines (one per row, header first).
parse_status_file() {
  local file="$1"

  local is_markdown=false
  while IFS= read -r probe; do
    if [[ "$probe" == *$'\t'* ]]; then
      break
    fi
    if [[ "$probe" == *"|"* ]]; then
      is_markdown=true
      break
    fi
  done < "$file"

  if $is_markdown; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" != *"|"* ]] && continue
      if [[ "$line" =~ ^[[:space:]]*\|[-[:space:]|]+\|[[:space:]]*$ ]]; then
        continue
      fi
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      line="${line#|}"
      line="${line%|}"
      local out=""
      local IFS='|'
      local -a parts
      read -ra parts <<< "$line"
      for part in "${parts[@]}"; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        [ -n "$out" ] && out+=$'\t'
        out+="$part"
      done
      printf '%s\n' "$out"
    done < "$file"
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '%s\n' "$line"
    done < "$file"
  fi
}

# Collect agent data lines. Outputs lines to stdout:
#   First line: source indicator ("dir", "dir_empty", "file", or "none")
#   Remaining lines: TSV data (no header) with the new schema:
#     agent_name \t ticket_ids \t start_timestamp \t summary \t last_action_raw
collect_agents() {
  if [ -d "$STATUS_DIR" ]; then
    local found=false
    local -a data_lines
    for f in "$STATUS_DIR"/*; do
      [ -f "$f" ] || continue
      found=true
      while IFS= read -r line; do
        [[ -n "$line" ]] && data_lines+=("$line")
      done < "$f"
    done
    if $found && [ ${#data_lines[@]} -gt 0 ]; then
      printf '%s\n' "dir"
      for dl in "${data_lines[@]}"; do
        printf '%s\n' "$dl"
      done
    else
      printf '%s\n' "dir_empty"
    fi
  elif [ -f ".agent-status.md" ]; then
    printf '%s\n' "file"
    local first=true
    while IFS= read -r line; do
      if $first; then
        first=false
        continue
      fi
      printf '%s\n' "$line"
    done < <(parse_status_file ".agent-status.md")
  elif [ -f "$HOME/.claude/agent-status.md" ]; then
    printf '%s\n' "file"
    local first=true
    while IFS= read -r line; do
      if $first; then
        first=false
        continue
      fi
      printf '%s\n' "$line"
    done < <(parse_status_file "$HOME/.claude/agent-status.md")
  else
    printf '%s\n' "none"
  fi
}

# Helper: repeat a character N times
repchar() { printf '%*s' "$2" '' | tr ' ' "$1"; }

# Render the table layout (normal/medium widths).
render_table() {
  local -a raw_lines=("$@")
  local -a lines
  local -a widths
  local ncols=0
  local term_width
  term_width=$(tput cols 2>/dev/null || printf '80')

  # Collect all ticket IDs for shared-prefix stripping
  local -a all_tickets
  for raw in "${raw_lines[@]}"; do
    IFS=$'\t' read -ra cells <<< "$raw"
    [[ -n "${cells[1]:-}" ]] && all_tickets+=("${cells[1]}")
  done

  # Find shared prefix across all tickets (split on comma for multi-ticket)
  local -a ticket_atoms
  for t in "${all_tickets[@]}"; do
    IFS=',' read -ra parts <<< "$t"
    for p in "${parts[@]}"; do
      p="${p#"${p%%[![:space:]]*}"}"
      p="${p%"${p##*[![:space:]]}"}"
      [[ -n "$p" ]] && ticket_atoms+=("$p")
    done
  done
  local shared_prefix=""
  if [ ${#ticket_atoms[@]} -gt 1 ]; then
    shared_prefix=$(common_prefix "${ticket_atoms[@]}")
    # Only strip prefix that ends on a word boundary (- or /)
    if [[ -n "$shared_prefix" ]] && [[ "$shared_prefix" != *"-" ]] && [[ "$shared_prefix" != *"/" ]]; then
      # Truncate to last - or /
      local trimmed="${shared_prefix%-*}"
      if [[ "$trimmed" != "$shared_prefix" ]]; then
        shared_prefix="${trimmed}-"
      else
        trimmed="${shared_prefix%/*}"
        if [[ "$trimmed" != "$shared_prefix" ]]; then
          shared_prefix="${trimmed}/"
        else
          shared_prefix=""
        fi
      fi
    fi
  fi

  # Build header
  local header
  header=$'Agent\tTicket(s)\tDuration\tSummary\tLast Action'

  # Columns: 0=Agent, 1=Ticket(s), 2=Duration, 3=Summary, 4=Last Action
  local -a visible_cols=(0 1 2 3 4)
  local -a col_headers=("Agent" "Ticket(s)" "Duration" "Summary" "Last Action")

  # Process data rows
  local -a processed_rows
  for raw in "${raw_lines[@]}"; do
    IFS=$'\t' read -ra cells <<< "$raw"
    local agent="${cells[0]:-}"
    local tickets="${cells[1]:-}"
    local start_ts="${cells[2]:-}"
    local summary="${cells[3]:-}"
    local last_action_raw="${cells[4]:-}"

    # Compute duration
    local duration
    duration=$(elapsed_since "$start_ts")

    # Strip shared prefix from tickets
    if [[ -n "$shared_prefix" ]] && [[ -n "$tickets" ]]; then
      local stripped=""
      IFS=',' read -ra tparts <<< "$tickets"
      for tp in "${tparts[@]}"; do
        tp="${tp#"${tp%%[![:space:]]*}"}"
        tp="${tp%"${tp##*[![:space:]]}"}"
        tp="${tp#"$shared_prefix"}"
        [ -n "$stripped" ] && stripped+=", "
        stripped+="$tp"
      done
      tickets="$stripped"
    fi

    # Format last action
    local last_action
    last_action=$(format_last_action "$last_action_raw")

    local row="${agent}"$'\t'"${tickets}"$'\t'"${duration}"$'\t'"${summary}"$'\t'"${last_action}"
    processed_rows+=("$row")
  done

  # Build display lines (header + data) with only visible columns
  local -a display_lines
  # Header
  local hdr_line=""
  for vc in "${visible_cols[@]}"; do
    [ -n "$hdr_line" ] && hdr_line+=$'\t'
    hdr_line+="${col_headers[$vc]}"
  done
  display_lines+=("$hdr_line")

  # Data
  for row in "${processed_rows[@]}"; do
    IFS=$'\t' read -ra all_cells <<< "$row"
    local disp_line=""
    for vc in "${visible_cols[@]}"; do
      [ -n "$disp_line" ] && disp_line+=$'\t'
      disp_line+="${all_cells[$vc]:-}"
    done
    display_lines+=("$disp_line")
  done

  # Calculate column widths
  ncols=${#visible_cols[@]}
  widths=()
  for ((i=0; i<ncols; i++)); do widths[$i]=0; done

  for line in "${display_lines[@]}"; do
    IFS=$'\t' read -ra cells <<< "$line"
    for ((i=0; i<ncols; i++)); do
      local len=${#cells[$i]}
      [ $len -gt ${widths[$i]:-0} ] && widths[$i]=$len
    done
  done

  [ $ncols -eq 0 ] && return

  # Add 2-char padding per column
  for ((i=0; i<ncols; i++)); do
    widths[$i]=$(( ${widths[$i]} + 2 ))
  done

  # Cap fixed-width columns: Agent(15), Ticket(12), Duration(12)
  local -a max_fixed=(15 12 12 0 0)
  for ((i=0; i<3 && i<ncols; i++)); do
    if [ ${max_fixed[$i]} -gt 0 ] && [ ${widths[$i]} -gt ${max_fixed[$i]} ]; then
      widths[$i]=${max_fixed[$i]}
    fi
  done

  # Target table width: terminal minus 2 chars left/right padding
  local target_width=$(( term_width - 4 ))
  local border_chars=$(( ncols + 1 ))  # │ between and around columns
  local available=$(( target_width - border_chars ))

  # Sum current fixed columns (0=Agent, 1=Ticket, 2=Duration)
  local fixed_total=0
  for ((i=0; i<3 && i<ncols; i++)); do
    fixed_total=$(( fixed_total + widths[i] ))
  done

  # Distribute remaining width to Summary (col 3) and Last Action (col 4)
  if [ $ncols -ge 5 ]; then
    local flex_space=$(( available - fixed_total ))
    if [ $flex_space -lt 10 ]; then flex_space=10; fi
    # Split 55% / 45% between Summary and Last Action
    local summary_w=$(( flex_space * 55 / 100 ))
    local action_w=$(( flex_space - summary_w ))
    # Ensure minimums
    [ $summary_w -lt 5 ] && summary_w=5
    [ $action_w -lt 5 ] && action_w=5
    widths[3]=$summary_w
    widths[4]=$action_w
  fi

  # Final shrink pass if table still exceeds terminal width
  local total=0
  for ((i=0; i<ncols; i++)); do total=$(( total + widths[i] )); done
  total=$(( total + border_chars ))
  local min_col=5
  if [ $total -gt $target_width ] && [ $ncols -gt 0 ]; then
    local excess=$(( total - target_width ))
    while [ $excess -gt 0 ]; do
      local widest=-1 widest_w=0
      for ((i=0; i<ncols; i++)); do
        if [ ${widths[$i]} -gt $min_col ] && [ ${widths[$i]} -gt $widest_w ]; then
          widest=$i
          widest_w=${widths[$i]}
        fi
      done
      [ $widest -lt 0 ] && break
      widths[$widest]=$(( widths[$widest] - 1 ))
      excess=$(( excess - 1 ))
    done
  fi

  # Build horizontal borders
  local top_border mid_border bot_border
  top_border="┌"
  mid_border="├"
  bot_border="└"
  for ((i=0; i<ncols; i++)); do
    local bar
    bar=$(repchar "─" "${widths[$i]}")
    if [ $i -lt $((ncols-1)) ]; then
      top_border+="${bar}┬"
      mid_border+="${bar}┼"
      bot_border+="${bar}┴"
    else
      top_border+="${bar}┐"
      mid_border+="${bar}┤"
      bot_border+="${bar}┘"
    fi
  done

  printf '  %s\n' "$top_border"

  local row_idx=0
  for line in "${display_lines[@]}"; do
    IFS=$'\t' read -ra cells <<< "$line"
    local row="│"
    for ((i=0; i<ncols; i++)); do
      local cell="${cells[$i]:-}"
      local w=${widths[$i]}
      local len=${#cell}
      local max_content=$(( w - 2 ))
      if [ $max_content -lt 1 ]; then max_content=1; fi
      if [ $len -gt $max_content ]; then
        if [ $max_content -ge 2 ]; then
          cell="${cell:0:$((max_content - 1))}…"
        else
          cell="${cell:0:$max_content}"
        fi
        len=${#cell}
      fi
      if [ $row_idx -eq 0 ]; then
        local pad=$(( (w - len) / 2 ))
        local rpad=$(( w - len - pad ))
        printf -v row '%s%*s%s%*s│' "$row" "$pad" '' "$cell" "$rpad" ''
      else
        local rpad=$(( w - len - 1 ))
        printf -v row '%s %s%*s│' "$row" "$cell" "$rpad" ''
      fi
    done
    printf '  %s\n' "$row"
    if [ $row_idx -eq 0 ]; then
      printf '  %s\n' "$mid_border"
    fi
    ((row_idx++))
  done

  printf '  %s\n' "$bot_border"
}

# Render the stacked/card layout for narrow panes (<60 cols).
render_cards() {
  local -a raw_lines=("$@")
  local term_width
  term_width=$(tput cols 2>/dev/null || printf '80')

  # Collect tickets for shared-prefix stripping
  local -a all_tickets
  for raw in "${raw_lines[@]}"; do
    IFS=$'\t' read -ra cells <<< "$raw"
    [[ -n "${cells[1]:-}" ]] && all_tickets+=("${cells[1]}")
  done

  local -a ticket_atoms
  for t in "${all_tickets[@]}"; do
    IFS=',' read -ra parts <<< "$t"
    for p in "${parts[@]}"; do
      p="${p#"${p%%[![:space:]]*}"}"
      p="${p%"${p##*[![:space:]]}"}"
      [[ -n "$p" ]] && ticket_atoms+=("$p")
    done
  done
  local shared_prefix=""
  if [ ${#ticket_atoms[@]} -gt 1 ]; then
    shared_prefix=$(common_prefix "${ticket_atoms[@]}")
    if [[ -n "$shared_prefix" ]] && [[ "$shared_prefix" != *"-" ]] && [[ "$shared_prefix" != *"/" ]]; then
      local trimmed="${shared_prefix%-*}"
      if [[ "$trimmed" != "$shared_prefix" ]]; then
        shared_prefix="${trimmed}-"
      else
        trimmed="${shared_prefix%/*}"
        if [[ "$trimmed" != "$shared_prefix" ]]; then
          shared_prefix="${trimmed}/"
        else
          shared_prefix=""
        fi
      fi
    fi
  fi

  local card_width=$(( term_width - 2 ))
  [ $card_width -lt 20 ] && card_width=20

  for raw in "${raw_lines[@]}"; do
    IFS=$'\t' read -ra cells <<< "$raw"
    local agent="${cells[0]:-}"
    local tickets="${cells[1]:-}"
    local start_ts="${cells[2]:-}"
    local summary="${cells[3]:-}"
    local last_action_raw="${cells[4]:-}"

    local duration
    duration=$(elapsed_since "$start_ts")

    # Strip shared prefix from tickets
    if [[ -n "$shared_prefix" ]] && [[ -n "$tickets" ]]; then
      local stripped=""
      IFS=',' read -ra tparts <<< "$tickets"
      for tp in "${tparts[@]}"; do
        tp="${tp#"${tp%%[![:space:]]*}"}"
        tp="${tp%"${tp##*[![:space:]]}"}"
        tp="${tp#"$shared_prefix"}"
        [ -n "$stripped" ] && stripped+=", "
        stripped+="$tp"
      done
      tickets="$stripped"
    fi

    local last_action
    last_action=$(format_last_action "$last_action_raw")

    # Card header: ── agent (ticket) ────
    local card_title="$agent"
    [[ -n "$tickets" ]] && card_title+=" ($tickets)"

    local title_len=${#card_title}
    local dashes_after=$(( card_width - title_len - 5 ))
    [ $dashes_after -lt 2 ] && dashes_after=2

    printf '── %s %s\n' "$card_title" "$(repchar '─' "$dashes_after")"

    # Truncate values to fit card width
    local label_width=10  # "Duration: " is longest at 10
    local value_max=$(( card_width - label_width ))
    [ $value_max -lt 5 ] && value_max=5

    printf ' Duration: %s\n' "${duration:0:$value_max}"
    if [ ${#summary} -gt $value_max ]; then
      printf ' Summary:  %s..\n' "${summary:0:$((value_max - 2))}"
    else
      printf ' Summary:  %s\n' "$summary"
    fi
    if [ ${#last_action} -gt $value_max ]; then
      printf ' Last:     %s..\n' "${last_action:0:$((value_max - 2))}"
    else
      printf ' Last:     %s\n' "$last_action"
    fi
    printf '\n'
  done
}

render_screen() {
  local term_width
  term_width=$(tput cols 2>/dev/null || printf '80')

  # Collect agent data; first line is the source indicator
  local agents_source="none"
  local -a agent_lines
  local first_line=true
  while IFS= read -r line; do
    if $first_line; then
      agents_source="$line"
      first_line=false
      continue
    fi
    [[ -n "$line" ]] && agent_lines+=("$line")
  done < <(collect_agents)

  # Build all output into a buffer
  local buf=""
  buf+="Agent Status"$'\n'$'\n'

  if [ "$agents_source" = "none" ] || [ "$agents_source" = "dir_empty" ]; then
    buf+="  No agents running."$'\n'
  elif [ ${#agent_lines[@]} -eq 0 ]; then
    buf+="  No agents running."$'\n'
  elif [ "$term_width" -lt 60 ]; then
    buf+="$(render_cards "${agent_lines[@]}")"$'\n'
  else
    buf+="$(render_table "${agent_lines[@]}")"$'\n'
  fi

  buf+=$'\n'"Updated $(date '+%H:%M:%S')"$'\n'

  # Pad each line to terminal width to overwrite stale content, then write all at once
  local padded=""
  local pad_fmt="%-${term_width}s"
  while IFS= read -r out_line; do
    printf -v padded_line "$pad_fmt" "$out_line"
    padded+="${padded_line}"$'\n'
  done <<< "$buf"

  # Position cursor at top-left, write buffer in one shot, then clear below
  tput cup 0 0 2>/dev/null
  printf '%s' "$padded"
  tput el 2>/dev/null
  tput ed 2>/dev/null
}

# Initial render
render_screen

if command -v fswatch &>/dev/null; then
  # Watch both the new directory and legacy file locations
  fswatch --latency 0.5 --one-per-batch \
    "$STATUS_DIR" ".agent-status.md" "$HOME/.claude/agent-status.md" 2>/dev/null \
  | while read -r _; do
    render_screen
  done
fi

# Fallback: poll every 5s
while true; do
  sleep 5
  render_screen
done
