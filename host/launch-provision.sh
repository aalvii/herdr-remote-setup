#!/usr/bin/env bash
# Clickable launcher for the host provisioning step.
#
# Behaviors:
#   - already in a terminal: run the GUI when zenity exists, else the text flow
#   - launched from a desktop icon (no terminal): open a terminal window and
#     run this script again there
#
# No arguments needed.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || dirname "$0")"
cd "$DIR" 2>/dev/null || exit 1
chmod +x provision.sh provision-gui.sh 2>/dev/null || true

if [ -t 1 ] || [ -t 0 ]; then
  if command -v zenity >/dev/null 2>&1; then
    exec ./provision-gui.sh
  else
    exec ./provision.sh
  fi
fi

# No terminal attached: open one that runs this same script.
if [ "$(uname -s)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
  exec open -a Terminal "$0"
fi
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "No graphical session detected."
  echo "Run: $DIR/provision.sh"
  exit 2
fi
if command -v xfce4-terminal >/dev/null 2>&1; then
  exec xfce4-terminal --title="Herdr Provision" --hold -e "$DIR/launch-provision.sh"
fi
if command -v gnome-terminal >/dev/null 2>&1; then
  exec gnome-terminal -- bash -c "'$DIR/launch-provision.sh'; echo; read -rp 'Press Enter to close'"
fi
if command -v konsole >/dev/null 2>&1; then
  exec konsole --hold -e "$DIR/launch-provision.sh"
fi
if command -v xterm >/dev/null 2>&1; then
  exec xterm -hold -e "$DIR/launch-provision.sh"
fi

echo "No terminal emulator found."
echo "Run: $DIR/provision.sh"
exit 2
