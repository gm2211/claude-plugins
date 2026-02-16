#!/bin/bash
# Watches deployment status via pluggable providers and renders a TUI table.
# Uses fswatch on .git/refs/remotes/ to detect pushes, falls back to polling.
#
# Keys: p = provider config, r = refresh, q = quit, ? = help

# Force UTF-8 for Unicode box-drawing characters
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# Hide cursor; restore on exit
cleanup() {
  tput cnorm 2>/dev/null
  # Kill background fswatch if running
  [[ -n "${FSWATCH_PID:-}" ]] && kill "$FSWATCH_PID" 2>/dev/null
  exit
}
trap cleanup INT TERM EXIT
tput civis 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROVIDERS_DIR="${SCRIPT_DIR}/providers"
CONFIG_FILE=".deploy-watch.json"

# State
CACHED_OUTPUT=""
SHOW_HELP=false
SHOW_PROVIDER_MENU=false
PROVIDER_MENU_STEP=""  # "select", "configure"
PROVIDER_MENU_SELECTION=""
SPINNER_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPINNER_IDX=0
REFRESH_TRIGGER=false
LAST_FETCH_TIME=0

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
C_RESET=$'\033[0m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_CYAN=$'\033[36m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_WHITE=$'\033[37m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Repeat a character N times
repchar() { printf '%*s' "$2" '' | tr ' ' "$1"; }

# Strip ANSI escape sequences to get visible length
strip_ansi() {
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

visible_len() {
  local stripped
  stripped=$(strip_ansi "$1")
  printf '%d' "${#stripped}"
}

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

spinner() {
  printf '%s' "${SPINNER_CHARS[$SPINNER_IDX]}"
  SPINNER_IDX=$(( (SPINNER_IDX + 1) % ${#SPINNER_CHARS[@]} ))
}

# Colorize a status string
colorize_status() {
  local status="$1"
  case "$status" in
    live|success)   printf '%s%s%s' "$C_GREEN" "$status" "$C_RESET" ;;
    building|deploying|pending)
                    printf '%s%s %s%s' "$C_YELLOW" "$status" "$(spinner)" "$C_RESET" ;;
    failed)         printf '%s%s%s' "$C_RED" "$status" "$C_RESET" ;;
    cancelled)      printf '%s%s%s' "$C_DIM" "$status" "$C_RESET" ;;
    *)              printf '%s' "$status" ;;
  esac
}

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

# Read a JSON key from config file (simple grep-based, no jq dependency)
config_get() {
  local key="$1"
  if [ ! -f "$CONFIG_FILE" ]; then
    return 1
  fi
  # Simple JSON value extraction -- handles "key": "value" patterns
  local val
  val=$(sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -1)
  if [ -n "$val" ]; then
    printf '%s' "$val"
    return 0
  fi
  return 1
}

# Read a nested JSON key: config_get_nested "render" "serviceId"
config_get_nested() {
  local section="$1" key="$2"
  if [ ! -f "$CONFIG_FILE" ]; then
    return 1
  fi
  # Extract value from nested object -- simple approach
  local in_section=false
  local val=""
  while IFS= read -r line; do
    if [[ "$line" == *"\"$section\""* ]] && [[ "$line" == *"{"* || "$line" == *":"* ]]; then
      in_section=true
      continue
    fi
    if $in_section; then
      if [[ "$line" == *"}"* ]]; then
        in_section=false
        continue
      fi
      local extracted
      extracted=$(printf '%s' "$line" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      if [ -n "$extracted" ]; then
        val="$extracted"
        break
      fi
    fi
  done < "$CONFIG_FILE"
  if [ -n "$val" ]; then
    printf '%s' "$val"
    return 0
  fi
  return 1
}

# List available provider scripts
list_providers() {
  local -a providers=()
  if [ -d "$PROVIDERS_DIR" ]; then
    for f in "$PROVIDERS_DIR"/*.sh; do
      [ -f "$f" ] || continue
      local name
      name=$(basename "$f" .sh)
      [ "$name" = "README" ] && continue
      providers+=("$name")
    done
  fi
  printf '%s\n' "${providers[@]}"
}

# Get the provider display name
provider_display_name() {
  local provider="$1"
  local script="${PROVIDERS_DIR}/${provider}.sh"
  if [ -x "$script" ]; then
    "$script" name 2>/dev/null || printf '%s' "$provider"
  else
    printf '%s' "$provider"
  fi
}

# Get provider config fields as lines: key|label|required|default
provider_config_fields() {
  local provider="$1"
  local script="${PROVIDERS_DIR}/${provider}.sh"
  if [ ! -x "$script" ]; then
    return 1
  fi
  local config_json
  config_json=$("$script" config 2>/dev/null) || return 1

  # Parse fields array from JSON -- simple line-by-line
  # Each field looks like: {"key":"...","label":"...","required":true/false,"default":"..."}
  printf '%s' "$config_json" | tr ',' '\n' | tr -d '[]{}' | while IFS= read -r line; do
    :  # placeholder -- we parse below with a different approach
  done

  # Better approach: extract field objects one per line
  # Remove outer structure, split on },{
  local fields_str
  fields_str=$(printf '%s' "$config_json" | sed 's/.*"fields"[[:space:]]*:[[:space:]]*\[//;s/\].*//')

  # Split on },{ to get individual field objects
  printf '%s' "$fields_str" | sed 's/},{/}\n{/g' | while IFS= read -r field; do
    local fkey flabel frequired fdefault
    fkey=$(printf '%s' "$field" | sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    flabel=$(printf '%s' "$field" | sed -n 's/.*"label"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    frequired="false"
    [[ "$field" == *'"required"'*'true'* ]] && frequired="true"
    fdefault=$(printf '%s' "$field" | sed -n 's/.*"default"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$fkey" ] && printf '%s|%s|%s|%s\n' "$fkey" "$flabel" "$frequired" "$fdefault"
  done
}

# Call the provider's list command, passing config via env vars
fetch_deploys() {
  local provider
  provider=$(config_get "provider") || return 1
  local script="${PROVIDERS_DIR}/${provider}.sh"
  if [ ! -x "$script" ]; then
    return 1
  fi

  # Build env vars from provider config section
  local -a env_args=()
  while IFS='|' read -r fkey flabel frequired fdefault; do
    [ -z "$fkey" ] && continue
    local val
    val=$(config_get_nested "$provider" "$fkey") || val="$fdefault"
    local env_key
    env_key="DEPLOY_WATCH_$(printf '%s' "$fkey" | tr '[:lower:]' '[:upper:]')"
    env_args+=("${env_key}=${val}")
  done < <(provider_config_fields "$provider")

  # Run the provider with env vars
  env "${env_args[@]}" "$script" list 2>/dev/null
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

render_deploy_table() {
  local -a json_lines=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && json_lines+=("$line")
  done <<< "$CACHED_OUTPUT"

  if [ ${#json_lines[@]} -eq 0 ]; then
    printf '  %sNo deploy data available.%s\n' "$C_DIM" "$C_RESET"
    return
  fi

  local term_width
  term_width=$(tput cols 2>/dev/null || printf '80')

  # Parse JSON lines into table rows
  local -a rows=()
  local service_url=""
  for jline in "${json_lines[@]}"; do
    local commit msg author build_status deploy_status build_started deploy_finished svc_url

    commit=$(printf '%s' "$jline" | sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    msg=$(printf '%s' "$jline" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    author=$(printf '%s' "$jline" | sed -n 's/.*"author"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    build_status=$(printf '%s' "$jline" | sed -n 's/.*"build_status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    deploy_status=$(printf '%s' "$jline" | sed -n 's/.*"deploy_status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    build_started=$(printf '%s' "$jline" | sed -n 's/.*"build_started"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    deploy_finished=$(printf '%s' "$jline" | sed -n 's/.*"deploy_finished"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    svc_url=$(printf '%s' "$jline" | sed -n 's/.*"service_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    [ -z "$service_url" ] && [ -n "$svc_url" ] && service_url="$svc_url"

    # Short commit
    local short_commit="${commit:0:7}"

    # Elapsed time
    local elapsed=""
    if [[ "$build_started" =~ ^[0-9]+$ ]]; then
      if [[ "$deploy_finished" =~ ^[0-9]+$ ]] && [ "$deploy_finished" -gt 0 ]; then
        local dur=$(( deploy_finished - build_started ))
        if [ $dur -lt 60 ]; then
          elapsed="${dur}s"
        elif [ $dur -lt 3600 ]; then
          elapsed="$(( dur / 60 ))m $(( dur % 60 ))s"
        else
          elapsed="$(( dur / 3600 ))h $(( (dur % 3600) / 60 ))m"
        fi
      else
        elapsed=$(elapsed_since "$build_started")
        elapsed="${elapsed} ago"
      fi
    fi

    # Truncate message
    local max_msg=40
    if [ ${#msg} -gt $max_msg ]; then
      msg="${msg:0:$((max_msg - 2))}.."
    fi

    rows+=("${short_commit}|${msg}|${build_status}|${deploy_status}|${elapsed}")
  done

  # Show service URL
  if [ -n "$service_url" ]; then
    printf '  %s%s%s\n\n' "$C_CYAN" "$service_url" "$C_RESET"
  fi

  # Determine column widths
  local -a headers=("Commit" "Message" "Build" "Deploy" "Elapsed")
  local -a widths=(8 10 10 10 10)

  # Update widths from data
  for row in "${rows[@]}"; do
    IFS='|' read -ra cells <<< "$row"
    for ((i=0; i<5; i++)); do
      local len=${#cells[$i]}
      [ $len -gt ${widths[$i]} ] && widths[$i]=$len
    done
  done

  # Update widths from headers
  for ((i=0; i<5; i++)); do
    local hlen=${#headers[$i]}
    [ $hlen -gt ${widths[$i]} ] && widths[$i]=$hlen
  done

  # Add padding
  for ((i=0; i<5; i++)); do
    widths[$i]=$(( ${widths[$i]} + 2 ))
  done

  # Shrink if too wide
  local total=0
  for ((i=0; i<5; i++)); do total=$(( total + widths[i] )); done
  total=$(( total + 6 ))  # 5 separators + 1
  if [ $total -gt $term_width ]; then
    local excess=$(( total - term_width ))
    # Shrink message column first
    if [ ${widths[1]} -gt 12 ]; then
      local can_shrink=$(( widths[1] - 12 ))
      [ $can_shrink -gt $excess ] && can_shrink=$excess
      widths[1]=$(( widths[1] - can_shrink ))
      excess=$(( excess - can_shrink ))
    fi
    # Then shrink other columns
    while [ $excess -gt 0 ]; do
      local widest=-1 widest_w=0
      for ((i=0; i<5; i++)); do
        if [ ${widths[$i]} -gt 6 ] && [ ${widths[$i]} -gt $widest_w ]; then
          widest=$i
          widest_w=${widths[$i]}
        fi
      done
      [ $widest -lt 0 ] && break
      widths[$widest]=$(( widths[$widest] - 1 ))
      excess=$(( excess - 1 ))
    done
  fi

  # Build borders
  local top_border="┌" mid_border="├" bot_border="└"
  for ((i=0; i<5; i++)); do
    local bar
    bar=$(repchar "─" "${widths[$i]}")
    if [ $i -lt 4 ]; then
      top_border+="${bar}┬"
      mid_border+="${bar}┼"
      bot_border+="${bar}┴"
    else
      top_border+="${bar}┐"
      mid_border+="${bar}┤"
      bot_border+="${bar}┘"
    fi
  done

  printf '%s\n' "$top_border"

  # Header row
  local hrow="│"
  for ((i=0; i<5; i++)); do
    local cell="${headers[$i]}"
    local w=${widths[$i]}
    local len=${#cell}
    local pad=$(( (w - len) / 2 ))
    local rpad=$(( w - len - pad ))
    printf -v hrow '%s%*s%s%s%s%*s│' "$hrow" "$pad" '' "$C_BOLD" "$cell" "$C_RESET" "$rpad" ''
  done
  printf '%s\n' "$hrow"
  printf '%s\n' "$mid_border"

  # Data rows
  for row in "${rows[@]}"; do
    IFS='|' read -ra cells <<< "$row"
    local drow="│"
    for ((i=0; i<5; i++)); do
      local cell="${cells[$i]:-}"
      local w=${widths[$i]}
      local max_content=$(( w - 2 ))
      [ $max_content -lt 1 ] && max_content=1

      # Truncate if needed
      if [ ${#cell} -gt $max_content ]; then
        if [ $max_content -ge 3 ]; then
          cell="${cell:0:$((max_content - 2))}.."
        else
          cell="${cell:0:$max_content}"
        fi
      fi

      # Colorize status columns
      local display_cell="$cell"
      if [ $i -eq 2 ] || [ $i -eq 3 ]; then
        display_cell=$(colorize_status "$cell")
      fi

      local visible_length=${#cell}
      local rpad=$(( w - visible_length - 1 ))
      [ $rpad -lt 0 ] && rpad=0
      printf -v drow '%s %s%*s│' "$drow" "$display_cell" "$rpad" ''
    done
    printf '%s\n' "$drow"
  done

  printf '%s\n' "$bot_border"
}

render_unconfigured() {
  local term_width
  term_width=$(tput cols 2>/dev/null || printf '80')

  printf '  %s%sNOT CONFIGURED%s\n\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
  printf '  Press %s[p]%s to select a deployment provider and configure.\n\n' "$C_BOLD" "$C_RESET"

  local -a providers=()
  while IFS= read -r p; do
    [ -n "$p" ] && providers+=("$p")
  done < <(list_providers)

  if [ ${#providers[@]} -gt 0 ]; then
    printf '  Available providers: %s\n\n' "${providers[*]}"
  else
    printf '  No providers found in %s\n\n' "$PROVIDERS_DIR"
  fi

  printf '  Or create %s.deploy-watch.json%s manually:\n' "$C_CYAN" "$C_RESET"
  printf '  {"provider": "render", "render": {"serviceId": "srv-xxx"}}\n'
}

render_help() {
  printf '\n'
  printf '  %sKeyboard Shortcuts%s\n\n' "$C_BOLD" "$C_RESET"
  printf '  %sp%s  Select/configure deployment provider\n' "$C_BOLD" "$C_RESET"
  printf '  %sr%s  Force refresh deploy data\n' "$C_BOLD" "$C_RESET"
  printf '  %sq%s  Quit\n' "$C_BOLD" "$C_RESET"
  printf '  %s?%s  Toggle this help\n' "$C_BOLD" "$C_RESET"
  printf '\n  Press any key to dismiss.\n'
}

render_provider_menu() {
  local -a providers=()
  while IFS= read -r p; do
    [ -n "$p" ] && providers+=("$p")
  done < <(list_providers)

  printf '\n'
  printf '  %sSelect a Provider%s\n\n' "$C_BOLD" "$C_RESET"

  if [ ${#providers[@]} -eq 0 ]; then
    printf '  No providers available.\n'
    printf '  Add provider scripts to: %s\n' "$PROVIDERS_DIR"
    printf '\n  Press any key to go back.\n'
    return
  fi

  local idx=1
  for p in "${providers[@]}"; do
    local display_name
    display_name=$(provider_display_name "$p")
    printf '  %s%d%s) %s\n' "$C_BOLD" "$idx" "$C_RESET" "$display_name"
    ((idx++))
  done

  printf '\n  Enter number (or q to cancel): '
}

# Interactive provider configuration -- collects field values and writes config
configure_provider() {
  local provider="$1"

  tput cnorm 2>/dev/null  # Show cursor for input

  printf '\n  %sConfiguring %s%s\n\n' "$C_BOLD" "$(provider_display_name "$provider")" "$C_RESET"

  local -a keys=()
  local -a values=()

  while IFS='|' read -r fkey flabel frequired fdefault; do
    [ -z "$fkey" ] && continue
    local prompt="  ${flabel}"
    [ -n "$fdefault" ] && prompt+=" [${fdefault}]"
    prompt+=": "
    printf '%s' "$prompt"

    local val
    read -r val
    [ -z "$val" ] && val="$fdefault"

    if [ "$frequired" = "true" ] && [ -z "$val" ]; then
      printf '  %sRequired field cannot be empty.%s\n' "$C_RED" "$C_RESET"
      tput civis 2>/dev/null
      return 1
    fi

    keys+=("$fkey")
    values+=("$val")
  done < <(provider_config_fields "$provider")

  # Build config JSON
  local config='{\n  "provider": "'"$provider"'"'

  if [ ${#keys[@]} -gt 0 ]; then
    config+=',\n  "'"$provider"'": {'
    local first=true
    for ((i=0; i<${#keys[@]}; i++)); do
      # Skip env var fields (they reference env vars, not stored values)
      # But still include all fields in config
      $first || config+=','
      config+='\n    "'"${keys[$i]}"'": "'"${values[$i]}"'"'
      first=false
    done
    config+='\n  }'
  fi

  config+='\n}'

  printf "$config" > "$CONFIG_FILE"

  printf '\n  %sConfiguration saved to %s%s\n' "$C_GREEN" "$CONFIG_FILE" "$C_RESET"
  sleep 1

  tput civis 2>/dev/null  # Hide cursor again
  return 0
}

FIRST_RENDER=true

render_screen() {
  if $FIRST_RENDER; then
    clear
    FIRST_RENDER=false
  else
    tput cup 0 0 2>/dev/null
    tput ed 2>/dev/null
  fi

  printf '%s%sDeploy Watch%s\n\n' "$C_BOLD" "$C_WHITE" "$C_RESET"

  if $SHOW_HELP; then
    render_help
    return
  fi

  if $SHOW_PROVIDER_MENU; then
    render_provider_menu
    return
  fi

  # Check configuration
  local provider
  provider=$(config_get "provider")
  if [ -z "$provider" ] || [ ! -f "$CONFIG_FILE" ]; then
    render_unconfigured
  else
    local provider_name
    provider_name=$(provider_display_name "$provider")
    printf '  Provider: %s%s%s\n' "$C_CYAN" "$provider_name" "$C_RESET"

    render_deploy_table
  fi

  printf '\n%sUpdated %s  |  [p]rovider  [r]efresh  [?]help  [q]uit%s\n' \
    "$C_DIM" "$(date '+%H:%M:%S')" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Data fetching
# ---------------------------------------------------------------------------

do_refresh() {
  local provider
  provider=$(config_get "provider") || return 1
  local output
  output=$(fetch_deploys 2>/dev/null) || return 1
  if [ -n "$output" ]; then
    CACHED_OUTPUT="$output"
  fi
  LAST_FETCH_TIME=$(date +%s)
}

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

handle_input() {
  local key="$1"

  if $SHOW_HELP; then
    SHOW_HELP=false
    return
  fi

  if $SHOW_PROVIDER_MENU; then
    local -a providers=()
    while IFS= read -r p; do
      [ -n "$p" ] && providers+=("$p")
    done < <(list_providers)

    if [[ "$key" == "q" ]] || [[ "$key" == "Q" ]]; then
      SHOW_PROVIDER_MENU=false
      return
    fi

    if [[ "$key" =~ ^[0-9]$ ]] && [ "$key" -ge 1 ] && [ "$key" -le ${#providers[@]} ]; then
      local selected="${providers[$((key - 1))]}"
      SHOW_PROVIDER_MENU=false
      clear
      printf '%s%sDeploy Watch%s\n' "$C_BOLD" "$C_WHITE" "$C_RESET"
      if configure_provider "$selected"; then
        REFRESH_TRIGGER=true
      fi
    fi
    return
  fi

  case "$key" in
    p|P)
      SHOW_PROVIDER_MENU=true
      ;;
    r|R)
      REFRESH_TRIGGER=true
      ;;
    q|Q)
      exit 0
      ;;
    '?')
      SHOW_HELP=true
      ;;
  esac
}

# ---------------------------------------------------------------------------
# fswatch trigger
# ---------------------------------------------------------------------------

TRIGGER_FILE=$(mktemp)

start_fswatch() {
  if command -v fswatch &>/dev/null && [ -d ".git/refs/remotes" ]; then
    fswatch --latency 1 --one-per-batch ".git/refs/remotes/" "$CONFIG_FILE" 2>/dev/null \
      | while read -r _; do
          printf '1' > "$TRIGGER_FILE"
        done &
    FSWATCH_PID=$!
  fi
}

check_fswatch_trigger() {
  if [ -f "$TRIGGER_FILE" ]; then
    local content
    content=$(cat "$TRIGGER_FILE" 2>/dev/null)
    if [ "$content" = "1" ]; then
      printf '' > "$TRIGGER_FILE"
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

start_fswatch

# Initial fetch
do_refresh
render_screen

POLL_INTERVAL=30
last_poll=$(date +%s)

while true; do
  # Non-blocking read with short timeout (for spinner animation)
  if read -rsn1 -t 2 key 2>/dev/null; then
    handle_input "$key"
  fi

  # Check if refresh was triggered (by key, fswatch, or poll)
  now=$(date +%s)

  if $REFRESH_TRIGGER; then
    REFRESH_TRIGGER=false
    do_refresh
    last_poll=$now
  elif check_fswatch_trigger; then
    do_refresh
    last_poll=$now
  elif (( now - last_poll >= POLL_INTERVAL )); then
    do_refresh
    last_poll=$now
  fi

  render_screen
done
