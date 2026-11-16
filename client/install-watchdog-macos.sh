#!/bin/bash
# Install or remove the herdr watchdog LaunchAgent (macOS).
#
# Usage:
#   bash install-watchdog-macos.sh [--interval-minutes 2]
#   bash install-watchdog-macos.sh --uninstall
#
# The LaunchAgent runs the watchdog in the user's GUI session so the watchdog
# can reopen Terminal and relaunch the TUI.

set -u

EXIT_OK=0
EXIT_PREREQ=2

LABEL="dev.herdr.watchdog"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG="$SCRIPT_DIR/watchdog-macos.sh"

INTERVAL_MINUTES=2
ACTION="install"
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --interval-minutes)
            if [ $# -lt 2 ]; then
                printf 'X --interval-minutes needs a value\n' >&2
                exit "$EXIT_PREREQ"
            fi
            INTERVAL_MINUTES="$2"
            shift 2
            ;;
        --interval-minutes=*)
            INTERVAL_MINUTES="${1#--interval-minutes=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --uninstall)
            ACTION="uninstall"
            shift
            ;;
        --help|-h)
            ACTION="help"
            shift
            ;;
        *)
            printf 'X unknown argument: %s\n' "$1" >&2
            exit "$EXIT_PREREQ"
            ;;
    esac
done

case "$INTERVAL_MINUTES" in
    ''|*[!0-9]*)
        printf 'X --interval-minutes must be a number\n' >&2
        exit "$EXIT_PREREQ"
        ;;
esac
if [ "$INTERVAL_MINUTES" -lt 1 ]; then
    printf 'X --interval-minutes must be at least 1\n' >&2
    exit "$EXIT_PREREQ"
fi
INTERVAL_SECONDS=$(( INTERVAL_MINUTES * 60 ))

if [ "$ACTION" = "help" ]; then
    cat <<'EOF'
Install or remove the herdr watchdog LaunchAgent (macOS).

Usage:
  bash install-watchdog-macos.sh [--interval-minutes 2]
  bash install-watchdog-macos.sh --dry-run
  bash install-watchdog-macos.sh --uninstall
EOF
    exit "$EXIT_OK"
fi

LOG_DIR="$HOME/Library/Logs/HerdrSetup"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
STDOUT_LOG="$LOG_DIR/watchdog.out.log"
STDERR_LOG="$LOG_DIR/watchdog.err.log"
UID_NUM="$(id -u)"

# A dry run validates a temporary plist and never touches an installed agent.
if [ "$DRY_RUN" -eq 1 ] && [ "$ACTION" = "install" ]; then
    PLIST="${TMPDIR:-/tmp}/$LABEL.$$.plist"
fi

unload_agent() {
    # bootout is the modern call; unload is the fallback for older releases.
    if launchctl bootout "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1; then
        return 0
    fi
    launchctl unload -w "$PLIST" >/dev/null 2>&1
    return $?
}

if [ "$ACTION" = "uninstall" ]; then
    if [ ! -f "$PLIST" ]; then
        printf 'LaunchAgent %s not present\n' "$LABEL"
        exit "$EXIT_OK"
    fi
    if unload_agent; then
        printf 'Unloaded LaunchAgent %s\n' "$LABEL"
    else
        printf 'LaunchAgent %s was not loaded\n' "$LABEL"
    fi
    rm -f "$PLIST"
    printf 'Removed %s\n' "$PLIST"
    exit "$EXIT_OK"
fi

if [ ! -f "$WATCHDOG" ]; then
    printf 'X watchdog-macos.sh not found next to this script (%s)\n' "$WATCHDOG" >&2
    exit "$EXIT_PREREQ"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || {
        printf 'X cannot create the log directory\n' >&2
        exit "$EXIT_PREREQ"
    }
else
    if ! mkdir -p "$LAUNCH_AGENTS" "$LOG_DIR" 2>/dev/null; then
        printf 'X cannot create the LaunchAgents or log directory\n' >&2
        exit "$EXIT_PREREQ"
    fi
fi

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Absolute paths only: launchd does not expand ~ or shell variables.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$(xml_escape "$WATCHDOG")</string>
        <string>--quiet</string>
    </array>
    <key>StartInterval</key>
    <integer>$INTERVAL_SECONDS</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$STDOUT_LOG")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$STDERR_LOG")</string>
</dict>
</plist>
EOF

if command -v plutil >/dev/null 2>&1; then
    _lint="$(plutil -lint "$PLIST" 2>&1)"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        rm -f "$PLIST"
        printf 'X plutil rejected %s: %s\n' "$PLIST" "$_lint" >&2
        exit "$EXIT_PREREQ"
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY RUN: plist is valid: %s\n' "$PLIST"
    printf 'ProgramArguments: /bin/bash %s --quiet\n' "$WATCHDOG"
    rm -f "$PLIST"
    exit "$EXIT_OK"
fi

# An already loaded agent makes bootstrap fail, so unload first. Errors are
# expected on a fresh install.
unload_agent >/dev/null 2>&1

_loaded=1
_load_out="$(launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>&1)"
if [ $? -ne 0 ]; then
    _load_out="$(launchctl load -w "$PLIST" 2>&1)"
    if [ $? -ne 0 ]; then
        _loaded=0
    fi
fi

if [ "$_loaded" -eq 0 ]; then
    printf 'X could not load %s: %s\n' "$PLIST" "$_load_out" >&2
    exit "$EXIT_PREREQ"
fi

printf 'Installed LaunchAgent %s (every %s min)\n' "$LABEL" "$INTERVAL_MINUTES"
printf 'Log: %s\n' "$LOG_DIR/watchdog.log"
printf 'Test: /bin/bash "%s" --dry-run\n' "$WATCHDOG"
exit "$EXIT_OK"
