#!/usr/bin/env bash
# Clickable launcher for the Herdr Remote Setup app on Linux and macOS.
#
# Behavior (same shape as host/launch-provision.sh):
#   - already in a terminal: run the shell app in place
#   - launched from a desktop icon (no terminal): open a terminal window and
#     run this script again there
#
# Bash 3.2 safe. ASCII only, LF only.

set -u

DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || dirname "$0")"
cd "$DIR" 2>/dev/null || exit 1

chmod +x "$DIR/herdr-setup.sh" "$DIR/launch-app.sh" 2>/dev/null || true
chmod +x "$DIR"/../host/*.sh "$DIR"/../client/*.sh 2>/dev/null || true

if [ -t 1 ] || [ -t 0 ]; then
  exec "$DIR/herdr-setup.sh"
fi

# No terminal attached: open one that runs this same script.
if [ "$(uname -s)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
  exec open -a Terminal "$DIR/launch-app.sh"
fi

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "No graphical session detected."
  echo "Run: $DIR/herdr-setup.sh"
  exit 2
fi

if command -v xfce4-terminal >/dev/null 2>&1; then
  exec xfce4-terminal --title="Herdr Remote Setup" --hold -e "$DIR/launch-app.sh"
fi
if command -v gnome-terminal >/dev/null 2>&1; then
  exec gnome-terminal -- bash -c "'$DIR/launch-app.sh'; echo; read -rp 'Press Enter to close'"
fi
if command -v konsole >/dev/null 2>&1; then
  exec konsole --hold -e "$DIR/launch-app.sh"
fi
if command -v xterm >/dev/null 2>&1; then
  exec xterm -hold -e "$DIR/launch-app.sh"
fi

echo "No terminal emulator found."
echo "Run: $DIR/herdr-setup.sh"
exit 2
