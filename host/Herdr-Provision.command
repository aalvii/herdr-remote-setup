#!/bin/bash
# Clickable macOS launcher. Double-click in Finder.
#
# This is the simple share flow. The host prints a 6-digit PIN. The other
# computer enters it. No connection code is needed.

DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || dirname "$0")"
cd "$DIR" 2>/dev/null || {
  echo "Cannot enter $DIR"
  read -r _
  exit 1
}

chmod +x launch-pair.sh pair.sh 2>/dev/null || true

./launch-pair.sh
RC=$?
echo ""
if [ "$RC" -ne 0 ]; then
  echo "Sharing stopped with exit $RC."
fi
echo "For the old connection-code flow, run: $DIR/provision.sh"
read -r -p "Press Enter to close" _
exit "$RC"
