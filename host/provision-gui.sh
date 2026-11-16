#!/usr/bin/env bash
# Herdr provisioning GUI (zenity).
# One dialog for the Tailscale auth key, then a ready connection code.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || dirname "$0")"
PROVISION="$SCRIPT_DIR/provision.sh"
VERSION="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "0.0.0")"
KEY_FILE="/etc/herdr-setup/authkey"

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "This GUI needs a desktop session. Run ./provision.sh in a terminal."
  exit 2
fi
if ! command -v zenity >/dev/null 2>&1; then
  echo "zenity is required. Debian/Ubuntu: sudo apt install zenity"
  exit 2
fi

AUTHKEY=""
if [ -r "$KEY_FILE" ]; then
  AUTHKEY="$(tr -d ' \r\n' < "$KEY_FILE")"
fi

if [ -z "$AUTHKEY" ]; then
  AUTHKEY="$(zenity --entry --hide-text --title="Tailscale auth key" \
    --text="Paste a one-time key (tskey-auth-...). It is needed so the new client can join your tailnet:" \
    --width=560 2>/dev/null || true)"
  if [ -z "$AUTHKEY" ]; then
    zenity --info --title="Cancelled" --text="No key entered." >/dev/null 2>&1
    exit 0
  fi
  if ! printf '%s' "$AUTHKEY" | grep -q '^tskey-'; then
    zenity --error --title="Bad key" --text="The auth key must start with tskey-." >/dev/null 2>&1
    exit 2
  fi
  if zenity --question --title="Save this key?" \
      --text="Store the key at $KEY_FILE (root only) so later runs need no input?" \
      --ok-label="Save" --cancel-label="Do not save" >/dev/null 2>&1; then
    printf '%s\n' "$AUTHKEY" | sudo tee "$KEY_FILE" >/dev/null 2>&1 || true
    sudo chmod 600 "$KEY_FILE" 2>/dev/null || true
    sudo chown root:root "$KEY_FILE" 2>/dev/null || true
  fi
fi

(
  echo "20"; echo "# Preparing host"
  sleep 0.3
  echo "55"; echo "# Starting enrollment endpoint"
  sleep 0.3
  echo "85"; echo "# Building connection code"
) | zenity --progress --title="Provisioning v$VERSION" --auto-close --no-cancel --width=420 >/dev/null 2>&1

OUT="$("$PROVISION" --authkey "$AUTHKEY" --ttl 3600 2>&1)"
RC=$?

if [ $RC -ne 0 ]; then
  zenity --error --title="Provisioning failed (exit $RC)" --width=640 \
    --text="$(printf '%s' "$OUT" | tail -c 3000 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')" >/dev/null 2>&1
  exit $RC
fi

CODE="$(printf '%s' "$OUT" | sed -n '/^Connection code$/,/^---/p' | grep -E '^[A-Za-z0-9+/=]+$' | head -1)"
if [ -z "$CODE" ]; then
  CODE="$(cat "$HOME/.local/state/herdr-setup/connection-code.txt" 2>/dev/null || true)"
fi
if [ -z "$CODE" ]; then
  zenity --error --title="No code" --text="The connection code could not be read. Run ./provision.sh in a terminal." >/dev/null 2>&1
  exit 6
fi

TEXT="Connection code (v$VERSION)&#10;&#10;<span font_family='monospace' size='small'>$CODE</span>&#10;&#10;Valid for about 1 hour. Paste it into the client setup."

if zenity --question --title="Connection code ready" --width=680 \
  --ok-label="Copy to clipboard" --cancel-label="Close" --text="$TEXT" >/dev/null 2>&1; then
  if command -v xclip >/dev/null 2>&1; then printf '%s' "$CODE" | xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then printf '%s' "$CODE" | xsel --clipboard --input
  elif command -v wl-copy >/dev/null 2>&1; then printf '%s' "$CODE" | wl-copy
  else
    zenity --warning --title="No clipboard tool" \
      --text="Install xclip, xsel, or wl-clipboard. The code is also in:&#10;$HOME/.local/state/herdr-setup/connection-code.txt" >/dev/null 2>&1
  fi
fi

exit 0
