#!/usr/bin/env bash
# Install desktop entries for the simple share and app flows.
#
# The Exec line must be an absolute path, so entries are generated here instead
# of being shipped with an author-specific path.
#
# Usage:
#   ./install-desktop.sh             install menu entries and Desktop shortcuts
#   ./install-desktop.sh --uninstall remove them

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || dirname "$0")"
PROV="$SCRIPT_DIR/launch-provision.sh"
SHARE="$SCRIPT_DIR/launch-pair.sh"
APP_LAUNCH="$(cd "$SCRIPT_DIR/../app" 2>/dev/null && pwd)/launch-app.sh"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_DIR="$HOME/Desktop"

TARGET="$APPS_DIR/herdr-remote-setup.desktop"
TARGET_SHARE="$APPS_DIR/herdr-share.desktop"
TARGET_PROV="$APPS_DIR/herdr-new-client-code.desktop"
TARGET_OLD_APP="$APPS_DIR/herdr-setup-app.desktop"

DESKTOP_TARGET="$DESKTOP_DIR/herdr-remote-setup.desktop"
DESKTOP_SHARE="$DESKTOP_DIR/herdr-share.desktop"
DESKTOP_OLD_APP="$DESKTOP_DIR/herdr-setup-app.desktop"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$TARGET" "$TARGET_SHARE" "$TARGET_PROV" "$TARGET_OLD_APP" \
        "$DESKTOP_TARGET" "$DESKTOP_SHARE" "$DESKTOP_OLD_APP" 2>/dev/null
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  fi
  echo "Removed desktop entries."
  exit 0
fi

[ -f "$APP_LAUNCH" ] || { echo "launch-app.sh not found: $APP_LAUNCH"; exit 2; }
[ -f "$SHARE" ] || { echo "launch-pair.sh not found: $SHARE"; exit 2; }

chmod +x "$APP_LAUNCH" "$SHARE" "$SCRIPT_DIR/pair.sh" "$SCRIPT_DIR/provision.sh" 2>/dev/null || true
[ -f "$PROV" ] && chmod +x "$PROV" 2>/dev/null || true

mkdir -p "$APPS_DIR" || { echo "cannot create $APPS_DIR"; exit 2; }
mkdir -p "$DESKTOP_DIR" 2>/dev/null || true

cat > "$TARGET" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Herdr Remote Setup
Comment=Share this computer or connect with a PIN
Exec=$APP_LAUNCH
Icon=utilities-terminal
Terminal=false
Categories=Network;
StartupNotify=true
EOF
chmod +x "$TARGET" 2>/dev/null || true

cat > "$TARGET_SHARE" <<EOF2
[Desktop Entry]
Version=1.0
Type=Application
Name=Herdr: Share This Computer
Comment=Show a 6-digit PIN so another computer can connect
Exec=$SHARE
Icon=utilities-terminal
Terminal=false
Categories=Network;
StartupNotify=true
EOF2
chmod +x "$TARGET_SHARE" 2>/dev/null || true

if [ -f "$PROV" ]; then
  cat > "$TARGET_PROV" <<EOF3
[Desktop Entry]
Version=1.0
Type=Application
Name=Herdr: New Client Code (Advanced)
Comment=Advanced connection-code flow
Exec=$PROV
Icon=utilities-terminal
Terminal=false
Categories=Network;
StartupNotify=true
EOF3
  chmod +x "$TARGET_PROV" 2>/dev/null || true
fi

# The old app entry duplicated the main entry. Remove it.
rm -f "$TARGET_OLD_APP" "$DESKTOP_OLD_APP" 2>/dev/null

if [ -d "$DESKTOP_DIR" ]; then
  cp "$TARGET" "$DESKTOP_TARGET" 2>/dev/null || true
  cp "$TARGET_SHARE" "$DESKTOP_SHARE" 2>/dev/null || true
  chmod +x "$DESKTOP_TARGET" "$DESKTOP_SHARE" 2>/dev/null || true
  if command -v gio >/dev/null 2>&1; then
    gio set "$DESKTOP_TARGET" metadata::trusted true >/dev/null 2>&1 || true
    gio set "$DESKTOP_SHARE" metadata::trusted true >/dev/null 2>&1 || true
  fi
fi

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
fi

echo "Installed menu entries in $APPS_DIR"
[ -f "$DESKTOP_TARGET" ] && echo "Desktop shortcut: $DESKTOP_TARGET"
[ -f "$DESKTOP_SHARE" ] && echo "Desktop shortcut: $DESKTOP_SHARE"
echo "Remove them with: $SCRIPT_DIR/install-desktop.sh --uninstall"
