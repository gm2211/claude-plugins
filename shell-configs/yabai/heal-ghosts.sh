#!/usr/bin/env sh
# Restart yabai when its layout still holds a window macOS has already closed.
#
# Apps that keep running after their last window closes (Notes, menu-bar apps
# like NordVPN) sometimes never send yabai the "window destroyed" event, so the
# dead window keeps its tile and the neighbour stays stuck at half screen.
# Those leftover entries report an empty AX role, and yabai refuses to act on
# them ("Could not locate the window"), so a restart is the only way to drop
# them. Called from signals in yabairc.
#
# A restart is expensive: yabai re-reads its config, reinstalls its event tap
# and re-tiles every window, and keyboard input can stall while it does. The
# first version restarted on ANY role-less window with a 30 s cooldown.
# Headless and background processes (Playwright browsers, Simulator hosts,
# osascript) own role-less windows all the time, so on 2026-11-08 it restarted
# yabai ~100 times in 6 hours and typing intermittently stopped reaching any
# app. So a ghost now has to be a real stuck tile: tiled (not floating), not
# minimized or hidden, on the space being looked at, and the same window id
# still there after a few seconds. Restarts are at most one per COOLDOWN.

PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
COOLDOWN=900
CONFIRM_DELAY=5
STAMP="${TMPDIR:-/tmp}/yabai-heal-ghosts.stamp"

# Cheap check first: bail out during the cooldown before querying anything.
now=$(date +%s)
last=$(cat "$STAMP" 2>/dev/null || echo 0)
[ $((now - last)) -lt "$COOLDOWN" ] && exit 0

# Ids of role-less windows that hold a tile on the current space.
stuck_tiles() {
  yabai -m query --windows --space 2>/dev/null | jq -r '
    [ .[]
      | select(.role == ""
               and ."is-floating" == false
               and ."is-minimized" == false
               and ."is-hidden" == false)
      | .id ] | sort | map(tostring) | join(",")'
}

first=$(stuck_tiles)
[ -n "$first" ] || exit 0
# A window can lack a role for a moment while it opens; confirm the same
# window is still stuck.
sleep "$CONFIRM_DELAY"
second=$(stuck_tiles)
[ -n "$second" ] && [ "$first" = "$second" ] || exit 0

echo "$now" > "$STAMP"
yabai --restart-service
