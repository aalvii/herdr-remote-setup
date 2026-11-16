#!/usr/bin/env bash
# Herdr Remote Setup - Host GUI (Linux, zenity)
# Thin wrapper: runs setup.sh and shows the connection code.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || dirname "$0")"
SETUP="$SCRIPT_DIR/setup.sh"
VERSION="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "0.0.0")"

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "This GUI needs a desktop session. Run ./setup.sh in a terminal instead."
  exit 2
fi

if ! command -v zenity >/dev/null 2>&1; then
  echo "zenity is required for the GUI."
  echo "Debian/Ubuntu: sudo apt install zenity"
  echo "Fedora:        sudo dnf install zenity"
  echo "Arch:          sudo pacman -S zenity"
  exit 2
fi

if [ ! -x "$SETUP" ]; then
  chmod +x "$SETUP" 2>/dev/null || true
fi

zenity --info --title="Herdr Remote Setup v$VERSION" --width=420 \
  --text="This prepares the machine for remote control.&#10;&#10;Optional: enter a Tailscale auth key on the next screen.&#10;Leave it empty if the other machine is already in your tailnet." \
  >/dev/null 2>&1 || exit 0

AUTHKEY="$(zenity --entry --title="Tailscale auth key (optional)" \
  --text="Paste a one-time key (tskey-auth-...), or leave empty:" --width=520 2>/dev/null || true)"

# Progress dialog while setup runs
(
  echo "5"; echo "# Preflight"
  sleep 0.3
  echo "25"; echo "# Network (Tailscale)"
  sleep 0.3
  echo "50"; echo "# herdr"
  sleep 0.3
  echo "75"; echo "# SSH"
  sleep 0.3
  echo "90"; echo "# Building connection code"
) | zenity --progress --title="Setting up" --auto-close --no-cancel --width=420 >/dev/null 2>&1

if [ -n "$AUTHKEY" ]; then
  OUT="$("$SETUP" --authkey "$AUTHKEY" 2>&1)"
else
  OUT="$("$SETUP" 2>&1)"
fi
RC=$?

if [ $RC -ne 0 ]; then
  zenity --error --title="Setup failed (exit $RC)" --width=620 \
    --text="$(printf '%s' "$OUT" | tail -c 3000 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')" >/dev/null 2>&1
  exit $RC
fi

CODE="$(printf '%s' "$OUT" | sed -n '/^Connection code$/,/^---------/p' | grep -E '^[A-Za-z0-9+/=]+$' | head -1)"
if [ -z "$CODE" ]; then
  # fall back to the saved copy
  CODE="$(cat "$HOME/.local/state/herdr-setup/connection-code.txt" 2>/dev/null || true)"
fi

if [ -z "$CODE" ]; then
  zenity --error --title="Setup finished" --text="Could not read the connection code. See the terminal output." >/dev/null 2>&1
  exit 6
fi

TEXT="Connection code (v$VERSION)&#10;&#10;<span font_family='monospace' size='small'>$CODE</span>&#10;&#10;Paste this into the client setup on the user machine."

if zenity --question --title="Connection code ready" --width=620 \
  --ok-label="Copy to clipboard" --cancel-label="Close" \
  --text="$TEXT" >/dev/null 2>&1; then
  if command -v xclip >/dev/null 2>&1; then
    printf '%s' "$CODE" | xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    printf '%s' "$CODE" | xsel --clipboard --input
  elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$CODE" | wl-copy
  else
    zenity --warning --title="Clipboard tool missing" \
      --text="Install xclip, xsel, or wl-clipboard. The code is also saved at:&#10;$HOME/.local/state/herdr-setup/connection-code.txt" >/dev/null 2>&1
  fi
fi

exit 0
