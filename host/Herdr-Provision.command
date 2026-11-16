#!/bin/bash
# Clickable macOS launcher. Double-click in Finder.
#
# A .command file opens Terminal. Keep the window open on failure so the
# error and the manual command stay readable.

DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || dirname "$0")"
cd "$DIR" 2>/dev/null || {
  echo "Cannot enter $DIR"
  read -r _
  exit 1
}

chmod +x launch-provision.sh provision.sh 2>/dev/null || true

./launch-provision.sh
RC=$?
echo ""
if [ "$RC" -ne 0 ]; then
  echo "Provisioning failed (exit $RC)."
  echo "Run: $DIR/provision.sh"
fi
# Keep the window open on success too: it holds the connection code.
read -r -p "Press Enter to close" _
exit "$RC"
