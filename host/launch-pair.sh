#!/usr/bin/env bash
# Clickable launcher for the simple host share flow.
#
# In a terminal it runs pair.sh. From a desktop icon it opens a terminal first.
# No arguments needed.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || dirname "$0")"
cd "$DIR" 2>/dev/null || exit 1
chmod +x pair.sh 2>/dev/null || true

if [ -t 1 ] || [ -t 0 ]; then
  exec bash ./pair.sh "$@"
fi

if [ "$(uname -s)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
  exec open -a Terminal "$DIR/launch-pair.sh"
fi

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "No graphical session detected."
  echo "Run: $DIR/pair.sh"
  exit 2
fi

if command -v xfce4-terminal >/dev/null 2>&1; then
  exec xfce4-terminal --title="Herdr Share" --hold -e "$DIR/launch-pair.sh"
fi
if command -v gnome-terminal >/dev/null 2>&1; then
  exec gnome-terminal -- bash -c "'$DIR/launch-pair.sh'; echo; read -rp 'Press Enter to close'"
fi
if command -v konsole >/dev/null 2>&1; then
  exec konsole --hold -e "$DIR/launch-pair.sh"
fi
if command -v xterm >/dev/null 2>&1; then
  exec xterm -hold -e "$DIR/launch-pair.sh"
fi

echo "No terminal emulator found."
echo "Run: $DIR/pair.sh"
exit 2
