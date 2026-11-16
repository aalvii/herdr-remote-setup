#!/usr/bin/env bash
# One-command provisioning for the host.
#
# Produces a ready-to-use connection code with:
#   - mode key (required for herdr)
#   - a Tailscale auth key for the client
#   - a one-time key enrollment token
#
# The auth key is resolved in this order, so a machine provisioned once needs
# no arguments again:
#   1. --authkey <key>
#   2. $HERDR_TS_AUTHKEY
#   3. /etc/herdr-setup/authkey
#   4. TS_AUTHKEY in /etc/herdr-setup/tailscale.env
#   5. interactive prompt (only when a terminal is attached)
#
# Usage:
#   ./provision.sh                       # use stored key, 1 hour enroll TTL
#   ./provision.sh --authkey tskey-...   # explicit key
#   ./provision.sh --save-key            # store the key for later runs (sudo)
#   ./provision.sh --clip                # copy the code to the clipboard
#   ./provision.sh --json                # machine-readable output
#
# Exit codes: 0 ok, 2 prerequisite, 3 network, 4 transport, 5 herdr, 6 internal.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || dirname "$0")"
CALLER_DIR="$(pwd)"
VERSION="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "0.0.0")"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-setup"
KEY_FILE="/etc/herdr-setup/authkey"
ENV_FILE="/etc/herdr-setup/tailscale.env"

AUTHKEY=""
TTL="${HERDR_ENROLL_TTL:-3600}"
PORT="${HERDR_ENROLL_PORT:-0}"
JSON=0
CLIP=0
SAVE_KEY=0
QUIET=0
SETUP_ARGS=()

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --authkey)    AUTHKEY="${2:-}"; shift 2 ;;
    --authkey=*)  AUTHKEY="${1#--authkey=}"; shift ;;
    --ttl)        TTL="${2:-}"; shift 2 ;;
    --ttl=*)      TTL="${1#--ttl=}"; shift ;;
    --port)       PORT="${2:-}"; shift 2 ;;
    --port=*)     PORT="${1#--port=}"; shift ;;
    --save-key)   SAVE_KEY=1; shift ;;
    --clip)       CLIP=1; shift ;;
    --json)       JSON=1; shift ;;
    --quiet)      QUIET=1; shift ;;
    --mode)       SETUP_ARGS+=("--mode" "${2:-}"); shift 2 ;;
    --mode=*)     SETUP_ARGS+=("--mode" "${1#--mode=}"); shift ;;
    --tag)        SETUP_ARGS+=("--tag" "${2:-}"); shift 2 ;;
    --tag=*)      SETUP_ARGS+=("--tag" "${1#--tag=}"); shift ;;
    --version)    echo "$VERSION"; exit 0 ;;
    --help|-h)    usage; exit 0 ;;
    *)            echo "unknown option: $1"; exit 2 ;;
  esac
done

[ -f "$SCRIPT_DIR/setup.sh" ] || { echo "setup.sh not found next to provision.sh"; exit 2; }

# ---------- resolve the auth key ----------
if [ -z "$AUTHKEY" ]; then
  AUTHKEY="${HERDR_TS_AUTHKEY:-}"
fi
if [ -z "$AUTHKEY" ] && [ -r "$KEY_FILE" ]; then
  AUTHKEY="$(tr -d ' \r\n' < "$KEY_FILE")"
fi
if [ -z "$AUTHKEY" ] && [ -r "$ENV_FILE" ]; then
  AUTHKEY="$(sed -n 's/^TS_AUTHKEY=//p' "$ENV_FILE" | head -1 | tr -d ' \r')"
fi
if [ -z "$AUTHKEY" ]; then
  if [ -t 0 ]; then
    printf 'Tailscale auth key (tskey-auth-...): '
    read -r AUTHKEY
  else
    echo "No auth key found. Provide --authkey, set HERDR_TS_AUTHKEY," >&2
    echo "write $KEY_FILE, or run with a terminal for the prompt." >&2
    exit 2
  fi
fi
case "$AUTHKEY" in
  tskey-*) : ;;
  *) echo "auth key must start with tskey-" >&2; exit 2 ;;
esac

# ---------- optionally persist the key ----------
if [ "$SAVE_KEY" -eq 1 ]; then
  if sudo -n true 2>/dev/null || [ "$(id -u)" -eq 0 ]; then
    sudo mkdir -p /etc/herdr-setup 2>/dev/null || mkdir -p /etc/herdr-setup
    printf '%s\n' "$AUTHKEY" | sudo tee "$KEY_FILE" >/dev/null 2>&1 || {
      echo "could not write $KEY_FILE" >&2; exit 2; }
    sudo chmod 600 "$KEY_FILE" 2>/dev/null || true
    sudo chown root:root "$KEY_FILE" 2>/dev/null || true
    [ "$QUIET" -eq 1 ] || echo "Saved auth key to $KEY_FILE (root only)"
  else
    echo "sudo is required for --save-key" >&2
    exit 2
  fi
fi

# ---------- run setup.sh ----------
mkdir -p "$STATE_DIR" 2>/dev/null || true
OUTFILE="$STATE_DIR/provision.out"
rm -f "$OUTFILE" 2>/dev/null || true

ARGS=(--mode key --authkey "$AUTHKEY" --enroll --enroll-ttl "$TTL" --enroll-port "$PORT")
if [ "${#SETUP_ARGS[@]}" -gt 0 ]; then
  # caller overrides mode/tag
  ARGS=("${SETUP_ARGS[@]}" --authkey "$AUTHKEY" --enroll --enroll-ttl "$TTL" --enroll-port "$PORT")
fi
if [ "$JSON" -eq 1 ]; then ARGS+=(--json); else ARGS+=(--quiet); fi

bash "$SCRIPT_DIR/setup.sh" "${ARGS[@]}" | tee "$OUTFILE"
RC=${PIPESTATUS[0]:-$?}

if [ "$RC" -ne 0 ]; then
  [ "$QUIET" -eq 1 ] && echo "provision failed with exit $RC; see $OUTFILE" >&2
  exit "$RC"
fi

# ---------- extract and optionally copy the code ----------
CODE=""
if [ "$JSON" -eq 1 ]; then
  CODE="$(sed -n 's/.*"code":"\([^"]*\)".*/\1/p' "$OUTFILE" | tail -1)"
else
  CODE="$(sed -n '/^Connection code$/,/^---/p' "$OUTFILE" | grep -E '^[A-Za-z0-9+/=]+$' | head -1)"
fi
[ -z "$CODE" ] && CODE="$(cat "$STATE_DIR/connection-code.txt" 2>/dev/null || true)"

if [ -n "$CODE" ] && [ "$CLIP" -eq 1 ]; then
  if [ "$(uname -s)" = "Darwin" ] && command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$CODE" | pbcopy && echo "Copied to clipboard"
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$CODE" | xclip -selection clipboard && echo "Copied to clipboard"
  elif command -v xsel >/dev/null 2>&1; then
    printf '%s' "$CODE" | xsel --clipboard --input && echo "Copied to clipboard"
  elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$CODE" | wl-copy && echo "Copied to clipboard"
  else
    echo "No clipboard tool found (pbcopy, xclip, xsel, or wl-clipboard)" >&2
  fi
fi

[ "$JSON" -eq 1 ] || { echo ""; echo "Ready. Send the code to the client machine."; }
cd "$CALLER_DIR" 2>/dev/null || true
exit 0
