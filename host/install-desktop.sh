#!/usr/bin/env bash
# Install desktop entries for the host flow and the app.
#
# The Exec line must be an absolute path, so entries are generated here instead
# of being shipped in the repository with an author-specific path.
#
# Usage:
#   ./install-desktop.sh             install menu entries and a Desktop shortcut
#   ./install-desktop.sh --uninstall remove them

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || dirname "$0")"
GUI="$SCRIPT_DIR/setup-gui.sh"
PROV="$SCRIPT_DIR/launch-provision.sh"
APP_LAUNCH="$(cd "$SCRIPT_DIR/../app" 2>/dev/null && pwd)/launch-app.sh"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_DIR="$HOME/Desktop"

TARGET="$APPS_DIR/herdr-remote-setup.desktop"
TARGET_PROV="$APPS_DIR/herdr-new-client-code.desktop"
TARGET_APP="$APPS_DIR/herdr-setup-app.desktop"
TARGET_SHORTCUT="$DESKTOP_DIR/herdr-setup-app.desktop"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$TARGET" "$TARGET_PROV" "$TARGET_APP" "$TARGET_SHORTCUT" 2>/dev/null
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  fi
  echo "Removed desktop entries."
  exit 0
fi

if [ ! -f "$GUI" ]; then
  echo "setup-gui.sh not found next to this script: $GUI"
  exit 2
fi
[ -f "$APP_LAUNCH" ] || { echo "launch-app.sh not found: $APP_LAUNCH"; exit 2; }

chmod +x "$GUI" "$SCRIPT_DIR/setup.sh" "$APP_LAUNCH" 2>/dev/null || true
[ -f "$PROV" ] && chmod +x "$PROV" 2>/dev/null || true
[ -f "$SCRIPT_DIR/provision.sh" ] && chmod +x "$SCRIPT_DIR/provision.sh" 2>/dev/null || true

mkdir -p "$APPS_DIR" || { echo "cannot create $APPS_DIR"; exit 2; }
mkdir -p "$DESKTOP_DIR" 2>/dev/null || true

cat > "$TARGET" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Herdr Remote Setup
Comment=Prepare this machine for remote control and print a connection code
Exec=$GUI
Icon=network-server
Terminal=false
Categories=Network;
StartupNotify=true
EOF

chmod +x "$TARGET" 2>/dev/null || true

if [ -f "$PROV" ]; then
  cat > "$TARGET_PROV" <<EOF2
[Desktop Entry]
Version=1.0
Type=Application
Name=Herdr: New Client Code
Comment=Generate a connection code for a new client machine (1 hour)
Exec=$PROV
Icon=utilities-terminal
Terminal=false
Categories=Network;
StartupNotify=true
EOF2
  chmod +x "$TARGET_PROV" 2>/dev/null || true
fi

cat > "$TARGET_APP" <<EOF3
[Desktop Entry]
Version=1.0
Type=Application
Name=Herdr Remote Setup (App)
Comment=Pick Role and OS and run the matching setup flow
Exec=$APP_LAUNCH
Icon=utilities-terminal
Terminal=false
Categories=Network;
StartupNotify=true
EOF3
chmod +x "$TARGET_APP" 2>/dev/null || true

if [ -d "$DESKTOP_DIR" ]; then
  cp "$TARGET_APP" "$TARGET_SHORTCUT" 2>/dev/null || true
  chmod +x "$TARGET_SHORTCUT" 2>/dev/null || true
  # GNOME needs the trusted flag before it runs a Desktop file.
  if command -v gio >/dev/null 2>&1; then
    gio set "$TARGET_SHORTCUT" metadata::trusted true >/dev/null 2>&1 || true
  fi
fi

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
fi

echo "Installed menu entries in $APPS_DIR"
[ -f "$TARGET_SHORTCUT" ] && echo "Desktop shortcut: $TARGET_SHORTCUT"
echo "Remove them with: $SCRIPT_DIR/install-desktop.sh --uninstall"
