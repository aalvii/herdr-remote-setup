#!/bin/bash
# Clickable macOS launcher. Double-click in Finder.
#
# A .command file opens Terminal. The shell app owns the flow; this wrapper
# keeps the window open afterwards (the host flow prints the connection code,
# which must stay readable) and reports the exit code on failure.
#
# Bash 3.2 safe. ASCII only, LF only.

set -u

DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || dirname "$0")"
cd "$DIR" 2>/dev/null || {
  echo "Cannot enter $DIR"
  read -r _
  exit 1
}

chmod +x herdr-setup.sh 2>/dev/null || true

# Run, not exec, so the exit code can be reported after the flow ends.
./herdr-setup.sh --no-pause "$@"
RC=$?

echo ""
if [ "$RC" -ne 0 ]; then
  echo "Herdr Setup failed (exit $RC)."
  echo "Run: $DIR/herdr-setup.sh"
fi
read -r -p "Press Enter to close" _
exit "$RC"
