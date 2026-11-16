#!/usr/bin/env bash
# Herdr Remote Setup - simple mode for Linux and macOS.
#
# One menu, two actions:
#   1) Share this computer   - show a 6-digit PIN
#   2) Connect to a computer - enter the host PIN
#   3) Advanced setup        - the old connection-code flow
#
# All old flags are passed to herdr-setup-advanced.sh, so automation and the
# previous workflows keep working.
#
# Bash 3.2 safe. ASCII only.

set -u

APP_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || dirname "$0")"
PKG_ROOT="$(cd "$APP_DIR/.." 2>/dev/null && pwd || dirname "$APP_DIR")"
VERSION="$(tr -d ' \t\r\n' < "$PKG_ROOT/VERSION" 2>/dev/null || echo "0.0.0")"
ADVANCED="$APP_DIR/herdr-setup-advanced.sh"

usage() {
  echo "Herdr Remote Setup v$VERSION"
  echo ""
  echo "Usage:"
  echo "  herdr-setup.sh                 simple menu"
  echo "  herdr-setup.sh --share         share this computer"
  echo "  herdr-setup.sh --connect       connect to a computer"
  echo "  herdr-setup.sh --self-test     advanced self-test"
  echo "  herdr-setup.sh --role ...      advanced flow (passed through)"
}

if [ $# -gt 0 ]; then
  case "$1" in
    --share)
      shift
      exec bash "$PKG_ROOT/host/pair.sh" "$@"
      ;;
    --connect)
      shift
      case "$(uname -s 2>/dev/null)" in
        Darwin)
          if [ -f "$PKG_ROOT/client/pair-macos.sh" ]; then
            exec bash "$PKG_ROOT/client/pair-macos.sh" "$@"
          fi
          echo "The PIN client is not available on macOS in this release."
          echo "Use the Advanced connection-code flow."
          exit 2
          ;;
        *)
          echo "The PIN client is for Windows and macOS. This is $(uname -s 2>/dev/null)."
          exit 2
          ;;
      esac
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      # Everything else is the advanced flow: --role, --os, --code,
      # --self-test, --dry-run, --no-pause.
      exec bash "$ADVANCED" "$@"
      ;;
  esac
fi

LOCAL_OS="$(uname -s 2>/dev/null)"
if [ "$LOCAL_OS" != "Linux" ] && [ "$LOCAL_OS" != "Darwin" ]; then
  echo "Unsupported operating system: $LOCAL_OS"
  exit 2
fi

if [ ! -t 0 ]; then
  echo "No terminal for the menu. Use --share, --connect, or the advanced flags." >&2
  exit 2
fi

echo ""
echo "================================================================"
echo "  Herdr Remote Setup v$VERSION"
echo "================================================================"
echo ""
echo "  1) Share this computer    (show a 6-digit PIN)"
echo "  2) Connect to a computer  (enter the host PIN)"
echo "  3) Advanced setup         (connection code)"
echo ""
printf 'Choice [1]: '
read -r choice
case "$choice" in
  1|"") exec bash "$PKG_ROOT/host/pair.sh" ;;
  2)
    case "$LOCAL_OS" in
      Darwin)
        if [ -f "$PKG_ROOT/client/pair-macos.sh" ]; then
          exec bash "$PKG_ROOT/client/pair-macos.sh"
        fi
        echo "The PIN client is not available on macOS in this release."
        echo "Use option 3, Advanced setup."
        exit 2
        ;;
      *)
        echo "The PIN client is for Windows and macOS. On Linux, use Advanced setup on a host."
        exit 2
        ;;
    esac
    ;;
  3) exec bash "$ADVANCED" ;;
  *) echo "Invalid choice: $choice" >&2; exit 2 ;;
esac
