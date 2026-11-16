#!/bin/bash
# Herdr remote watchdog (macOS).
# Detects the known "surface revocation" stall (herdr issue #3842) and
# restarts only the local client. The local server, panes, and the remote
# server are left untouched.
#
# Usage:
#   bash watchdog-macos.sh [--dry-run] [--stale-minutes 3] [--quiet] [--client-log PATH]
#
# Exit codes:
#   0  healthy, nothing to do
#   2  cannot evaluate (missing files, no herdr, no Terminal automation)
#   10 client restarted
#   11 dry run: restart needed

set -u

EXIT_OK=0
EXIT_CANNOT=2
EXIT_RESTARTED=10
EXIT_DRYRUN=11

DRY_RUN=0
STALE_MINUTES=3
QUIET=0
CLIENT_LOG_ARG=""
ACTION="run"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --stale-minutes)
            if [ $# -lt 2 ]; then
                printf 'X --stale-minutes needs a value\n' >&2
                exit "$EXIT_CANNOT"
            fi
            STALE_MINUTES="$2"
            shift 2
            ;;
        --stale-minutes=*)
            STALE_MINUTES="${1#--stale-minutes=}"
            shift
            ;;
        --quiet|-q)
            QUIET=1
            shift
            ;;
        --client-log)
            if [ $# -lt 2 ]; then
                printf 'X --client-log needs a value\n' >&2
                exit "$EXIT_CANNOT"
            fi
            CLIENT_LOG_ARG="$2"
            shift 2
            ;;
        --client-log=*)
            CLIENT_LOG_ARG="${1#--client-log=}"
            shift
            ;;
        --help|-h)
            ACTION="help"
            shift
            ;;
        *)
            printf 'X unknown argument: %s\n' "$1" >&2
            exit "$EXIT_CANNOT"
            ;;
    esac
done

case "$STALE_MINUTES" in
    ''|*[!0-9]*)
        printf 'X --stale-minutes must be a number\n' >&2
        exit "$EXIT_CANNOT"
        ;;
esac

if [ "$ACTION" = "help" ]; then
    cat <<'EOF'
Herdr remote watchdog (macOS)

Usage:
  bash watchdog-macos.sh [--dry-run] [--stale-minutes N] [--quiet] [--client-log PATH]

  --dry-run            Report what would be stopped, exit 11
  --stale-minutes N    Only act when the client log is older than N minutes (default 3)
  --quiet              Do not write to stdout
  --client-log PATH    Override the client log path

Exit codes: 0 healthy, 2 cannot evaluate, 10 restarted, 11 dry run
EOF
    exit "$EXIT_OK"
fi

LOG_DIR="$HOME/Library/Logs/HerdrSetup"
WATCHDOG_LOG="$LOG_DIR/watchdog.log"
mkdir -p "$LOG_DIR" 2>/dev/null

log() {
    _line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $1"
    printf '%s\n' "$_line" >> "$WATCHDOG_LOG" 2>/dev/null
    if [ "$QUIET" -eq 0 ]; then
        printf '%s\n' "$_line"
    fi
}

# The macOS herdr client log path was not observed on a real Mac. This list is
# an assumption based on the Linux and Windows locations:
#   ~/Library/Application Support/herdr/herdr-client.log  (Application Support layout)
#   ~/.config/herdr/herdr-client.log                     (XDG layout)
#   ~/Library/Logs/herdr/herdr-client.log                (Logs layout)
# Override with --client-log or HERDR_CLIENT_LOG once the real path is known.
CLIENT_LOG=""
if [ -n "$CLIENT_LOG_ARG" ]; then
    CLIENT_LOG="$CLIENT_LOG_ARG"
elif [ -n "${HERDR_CLIENT_LOG:-}" ]; then
    CLIENT_LOG="$HERDR_CLIENT_LOG"
else
    for _p in \
        "$HOME/Library/Application Support/herdr/herdr-client.log" \
        "$HOME/.config/herdr/herdr-client.log" \
        "$HOME/Library/Logs/herdr/herdr-client.log"
    do
        if [ -f "$_p" ]; then
            CLIENT_LOG="$_p"
            break
        fi
    done
fi

if [ -z "$CLIENT_LOG" ]; then
    log "no client log found (checked Application Support, .config, Library/Logs)"
    exit "$EXIT_CANNOT"
fi
if [ ! -f "$CLIENT_LOG" ]; then
    log "no client log at $CLIENT_LOG"
    exit "$EXIT_CANNOT"
fi

state="unknown"
last_line=""
seen=0

while IFS= read -r _l; do
    seen=1
    case "$_l" in
        *"handshake succeeded"*)
            state="ok"
            last_line="$_l"
            ;;
        *"did not acknowledge surface revocation"*|*"endpoint health check timed out"*)
            state="stuck"
            last_line="$_l"
            ;;
        *"endpoint transport failed"*|*"connection was lost"*)
            state="fail"
            last_line="$_l"
            ;;
    esac
done < <(tail -n 120 "$CLIENT_LOG" 2>/dev/null)

if [ "$seen" -eq 0 ]; then
    log "client log is empty"
    exit "$EXIT_OK"
fi

# BSD stat does not accept GNU date -r, so read the mtime directly.
_now="$(date +%s)"
_mtime="$(stat -f %m "$CLIENT_LOG" 2>/dev/null)"
case "$_mtime" in
    ''|*[!0-9]*) _mtime="$_now" ;;
esac
_age_sec=$(( _now - _mtime ))
if [ "$_age_sec" -lt 0 ]; then
    _age_sec=0
fi
_age_min=$(( _age_sec / 60 ))

log "state=$state logAge=${_age_min}min last=${last_line}"

if [ "$state" = "ok" ]; then
    exit "$EXIT_OK"
fi

_stale_sec=$(( STALE_MINUTES * 60 ))
if [ "$_age_sec" -lt "$_stale_sec" ]; then
    log "recent activity; waiting"
    exit "$EXIT_OK"
fi

# Find the TUI client only: the local server, the remote bridge, and this
# watchdog must never be stopped.
PIDS=""
for _pid in $(pgrep -f 'herdr' 2>/dev/null); do
    _cmd="$(ps -o command= -p "$_pid" 2>/dev/null)"
    if [ -z "$_cmd" ]; then
        continue
    fi
    case "$_cmd" in
        *"herdr server"*) continue ;;
        *"remote-client-bridge"*) continue ;;
        *"watchdog-macos.sh"*) continue ;;
    esac
    PIDS="$PIDS $_pid"
done
PIDS="${PIDS# }"

if [ -z "$PIDS" ]; then
    log "no local client process; nothing to restart"
    exit "$EXIT_OK"
fi

_csv=""
for _pid in $PIDS; do
    if [ -z "$_csv" ]; then
        _csv="$_pid"
    else
        _csv="$_csv,$_pid"
    fi
done

if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: would stop $_csv and relaunch"
    exit "$EXIT_DRYRUN"
fi

for _pid in $PIDS; do
    log "stopping client pid=$_pid"
    kill -9 "$_pid" 2>/dev/null
done

sleep 3

HERDR=""
if command -v herdr >/dev/null 2>&1; then
    HERDR="$(command -v herdr)"
else
    for _p in "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do
        if [ -x "$_p" ]; then
            HERDR="$_p"
            break
        fi
    done
fi
if [ -z "$HERDR" ]; then
    log "herdr not found"
    exit "$EXIT_CANNOT"
fi

# A TUI needs a console, and this watchdog runs from launchd with no terminal.
# Terminal opens a window and runs the client; osascript must exist beforehand.
if ! command -v osascript >/dev/null 2>&1; then
    log "osascript not found; cannot relaunch the client in Terminal"
    exit "$EXIT_CANNOT"
fi

_esc="$(printf '%s' "$HERDR" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"

if ! osascript -e 'tell application "Terminal" to do script "exec '"$_esc"'"' >/dev/null 2>&1; then
    log "osascript failed to open a Terminal window"
    exit "$EXIT_CANNOT"
fi
if ! osascript -e 'tell application "Terminal" to activate' >/dev/null 2>&1; then
    log "osascript failed to activate Terminal"
    exit "$EXIT_CANNOT"
fi

log "relaunched $HERDR in Terminal"
exit "$EXIT_RESTARTED"
