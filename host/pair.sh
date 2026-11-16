#!/usr/bin/env bash
# Simple host share flow.
#
# Checks Tailscale, sshd, and herdr, then starts the PIN pairing service on the
# Tailscale address. The user reads the 6-digit PIN to the other computer.
#
# Usage:
#   ./pair.sh
#   ./pair.sh --ttl 900
#   ./pair.sh --no-join-code               # PIN only, no tailnet join code
#   ./pair.sh --no-acl-write               # check the ACL, never write it
#   ./pair.sh --pin 123456 --once          # tests
#
# When /etc/herdr-setup/tailscale-api.key exists, the share flow also ensures
# the tailnet policy allows tag:client and prints a one-time guest join code.
#
# Exit codes: 0 ok, 2 prerequisite, 3 network, 4 transport, 5 herdr.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || dirname "$0")"
VERSION="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "0.0.0")"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-setup"
PORT="${HERDR_PAIR_PORT:-8765}"
BIND=""
NO_JOIN_CODE=0
NO_ACL_WRITE=0
PAIR_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --port=*) PORT="${1#--port=}"; shift ;;
    --bind) BIND="${2:-}"; shift 2 ;;
    --bind=*) BIND="${1#--bind=}"; shift ;;
    --no-join-code) NO_JOIN_CODE=1; shift ;;
    --no-acl-write) NO_ACL_WRITE=1; shift ;;
    --help|-h) sed -n '/^# Simple host share/,/^# Exit codes/p' "$0"; exit 0 ;;
    *) PAIR_ARGS+=("$1"); shift ;;
  esac
done

die() { local c="$1"; shift; echo "X $*" >&2; exit "$c"; }

OS="$(uname -s)"
case "$OS" in
  Linux|Darwin) ;;
  *) die 2 "this host flow supports Linux and macOS only (found $OS)" ;;
esac

command -v python3 >/dev/null 2>&1 || die 2 "python3 is required (macOS: xcode-select --install)"

# ---------- Tailscale ----------
TS="$(command -v tailscale 2>/dev/null || true)"
[ -z "$TS" ] && [ -x /usr/bin/tailscale ] && TS=/usr/bin/tailscale
[ -z "$TS" ] && [ -x /usr/local/bin/tailscale ] && TS=/usr/local/bin/tailscale
[ -z "$TS" ] && [ -x /opt/homebrew/bin/tailscale ] && TS=/opt/homebrew/bin/tailscale
[ -z "$TS" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -n "$TS" ] || die 3 "Tailscale not found. Install it and join the tailnet first."

"$TS" status >/dev/null 2>&1 || die 3 "Tailscale is not connected. Run 'sudo tailscale up' first."

# Tailscale changed the short flag in 1.104: --4 works, -4 is rejected.
ts_ipv4() {
  local ip=""
  ip="$("$1" ip --4 2>/dev/null | grep -E '^100\.' | head -1)"
  [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
  ip="$("$1" ip 2>/dev/null | grep -E '^100\.' | head -1)"
  [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
  ip="$("$1" ip -4 2>/dev/null | grep -E '^100\.' | head -1)"
  [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
  return 1
}

TS_IP="$(ts_ipv4 "$TS")"
[ -n "$TS_IP" ] || die 3 "No Tailscale IPv4 address. Run 'tailscale up' first."
[ -n "$BIND" ] || BIND="$TS_IP"

# ---------- sshd ----------
SSH_OK=0
if [ "$OS" = "Darwin" ]; then
  pgrep -x sshd >/dev/null 2>&1 && SSH_OK=1
  [ "$SSH_OK" -eq 0 ] && sudo -n launchctl print system/com.openssh.sshd >/dev/null 2>&1 && SSH_OK=1
  if [ "$SSH_OK" -eq 0 ]; then
    sudo -n systemsetup -setremotelogin on >/dev/null 2>&1 || true
    sleep 1
    pgrep -x sshd >/dev/null 2>&1 && SSH_OK=1
  fi
  [ "$SSH_OK" -eq 1 ] || die 4 "SSH is off. Enable System Settings > General > Sharing > Remote Login."
else
  command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet sshd 2>/dev/null && SSH_OK=1
  command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ssh 2>/dev/null && SSH_OK=1
  [ "$SSH_OK" -eq 0 ] && pgrep -x sshd >/dev/null 2>&1 && SSH_OK=1
  if [ "$SSH_OK" -eq 0 ]; then
    sudo -n systemctl start sshd >/dev/null 2>&1 || sudo -n systemctl start ssh >/dev/null 2>&1 || true
    sleep 1
    pgrep -x sshd >/dev/null 2>&1 && SSH_OK=1
  fi
  [ "$SSH_OK" -eq 1 ] || die 4 "SSH server is not running. Start sshd and rerun."
fi

# ---------- herdr ----------
HERDR="$(command -v herdr 2>/dev/null || true)"
[ -z "$HERDR" ] && [ -x "$HOME/.local/bin/herdr" ] && HERDR="$HOME/.local/bin/herdr"
[ -z "$HERDR" ] && [ -x /opt/homebrew/bin/herdr ] && HERDR=/opt/homebrew/bin/herdr
[ -z "$HERDR" ] && [ -x /usr/local/bin/herdr ] && HERDR=/usr/local/bin/herdr
if [ -z "$HERDR" ]; then
  echo ">> Installing herdr"
  curl -fsSL https://herdr.dev/install.sh | sh || die 5 "herdr install failed"
  export PATH="$HOME/.local/bin:$PATH"
  HERDR="$(command -v herdr 2>/dev/null || true)"
  [ -z "$HERDR" ] && [ -x "$HOME/.local/bin/herdr" ] && HERDR="$HOME/.local/bin/herdr"
fi
[ -n "$HERDR" ] || die 5 "herdr not found after install"

start_detached() {
  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$@" </dev/null >/dev/null 2>&1
  else
    python3 -c 'import subprocess,sys; subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)' "$@"
  fi
}

if ! "$HERDR" status 2>&1 | grep -q "status: running"; then
  echo ">> Starting herdr server"
  start_detached "$HERDR" server
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    "$HERDR" status 2>&1 | grep -q "status: running" && break
  done
  "$HERDR" status 2>&1 | grep -q "status: running" || die 5 "herdr server did not start"
fi

mkdir -p "$HOME/.ssh" 2>/dev/null || true
chmod 700 "$HOME/.ssh" 2>/dev/null || true
touch "$HOME/.ssh/authorized_keys" 2>/dev/null || true
chmod 600 "$HOME/.ssh/authorized_keys" 2>/dev/null || true
mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---------- guest join code ----------
# A missing or rejected API token must never stop the PIN flow.
run_root() {
  if sudo -n true 2>/dev/null; then sudo -n "$@"; else sudo "$@"; fi
}

JOIN_CODE=""
JOIN_STATE="off"
if [ "$NO_JOIN_CODE" -eq 1 ]; then
  JOIN_STATE="off"
elif ! "$TS" status --json 2>/dev/null | grep -q 'tag:herdr-host'; then
  echo "! This host is not tagged tag:herdr-host."
  echo "  Apply it with: sudo tailscale up --advertise-tags=tag:herdr-host"
  JOIN_STATE="untagged"
else
  ENSURE_ARGS=()
  [ "$NO_ACL_WRITE" -eq 1 ] && ENSURE_ARGS+=(--no-acl-write)
  run_root bash "$SCRIPT_DIR/ensure-acl.sh" ${ENSURE_ARGS[@]+"${ENSURE_ARGS[@]}"}
  ACL_RC=$?
  if [ "$ACL_RC" -eq 2 ]; then
    echo "! No Tailscale API token. PIN-only; the guest must already be on the tailnet."
    JOIN_STATE="no-token"
  elif [ "$ACL_RC" -ne 0 ]; then
    echo "! The tailnet ACL is not ready. PIN-only for now."
    JOIN_STATE="acl"
  else
    JOIN_CODE="$(run_root bash "$SCRIPT_DIR/guest-key.sh" 2>"$STATE_DIR/guest-key.err")"
    JOIN_CODE="$(printf '%s' "$JOIN_CODE" | tr -d '[:space:]')"
    case "$JOIN_CODE" in
      tskey-auth-*) JOIN_STATE="ready" ;;
      *)
        JOIN_CODE=""
        JOIN_STATE="key"
        echo "! Could not create a guest join code. PIN-only for now."
        sed -n '1,3p' "$STATE_DIR/guest-key.err" 2>/dev/null
        ;;
    esac
  fi
fi

echo ""
echo "Herdr Share v$VERSION"
echo "  Computer : $(hostname 2>/dev/null || echo unknown)"
echo "  User     : $(whoami 2>/dev/null || echo user)"
echo "  Address  : $BIND:$PORT"
echo "  herdr    : $("$HERDR" --version 2>/dev/null | head -1)"
echo ""

if [ -n "$JOIN_CODE" ]; then
  echo "Guest join code: $JOIN_CODE"
  echo ""
fi

exec python3 "$SCRIPT_DIR/pair.py" \
  --bind "$BIND" \
  --port "$PORT" \
  --state-dir "$STATE_DIR" \
  ${PAIR_ARGS[@]+"${PAIR_ARGS[@]}"}
