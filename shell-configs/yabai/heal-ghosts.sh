#!/usr/bin/env sh
# Restart yabai when its layout still holds a window macOS has already closed.
#
# Apps that keep running after their last window closes (Notes, menu-bar apps
# like NordVPN) sometimes never send yabai the "window destroyed" event, so the
# dead window keeps its tile and the neighbour stays stuck at half screen.
# Those leftover entries report an empty AX role, and yabai refuses to act on
# them ("Could not locate the window"), so a restart is the only way to drop
# them. Called from signals in yabairc; the check costs ~20 ms.

PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
COOLDOWN=30
STAMP="${TMPDIR:-/tmp}/yabai-heal-ghosts.stamp"

has_ghost() {
  yabai -m query --windows 2>/dev/null | jq -e 'any(.[]; .role == "")' >/dev/null
}

has_ghost || exit 0
# A window can lack a role for a moment while it opens; confirm it sticks.
sleep 1
has_ghost || exit 0

# Never restart more than once per COOLDOWN seconds, so a ghost that survives
# a restart can't cause a restart loop.
now=$(date +%s)
last=$(cat "$STAMP" 2>/dev/null || echo 0)
[ $((now - last)) -lt "$COOLDOWN" ] && exit 0
echo "$now" > "$STAMP"

yabai --restart-service
