#!/usr/bin/env bash
# Herdr Remote Setup - thin cross-platform front end for Linux and macOS.
#
# Why a shell menu and not Tkinter: the Linux host has python3 but no tkinter
# and no DISPLAY, and the macOS Command Line Tools python3 does not ship tkinter
# reliably. A POSIX shell menu needs no third-party runtime. Windows uses
# app/herdr-setup.ps1 (WinForms, present with PowerShell 5.1).
#
# The scripts under host/ and client/ are the source of truth and are never
# modified here.
#
# Bash 3.2 safe (macOS): no associative arrays, no mapfile, no ${var,,}.
# ASCII only, LF only.

set -u

APP_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || dirname "$0")"
PKG_ROOT="$(cd "$APP_DIR/.." 2>/dev/null && pwd || dirname "$APP_DIR")"

VERSION="0.0.0"
if [ -f "$PKG_ROOT/VERSION" ]; then
  VERSION="$(tr -d ' \t\r\n' < "$PKG_ROOT/VERSION")"
fi

# ---------------------------------------------------------------------------
# The support matrix: Role|Os|Kind|Path|Message. This is the only table.
# ---------------------------------------------------------------------------
MATRIX='Host|Linux|run|host/provision.sh|Runs on the Linux host. Generate the connection code there, then send it to the client.
Host|macOS|run|host/provision.sh|Runs on the macOS host. Generate the connection code there, then send it to the client.
Host|Windows|unsupported||Host mode is not shipped for Windows. Run host/provision.sh on the Linux host or the macOS host.
Client|Linux|unsupported||Client mode is not shipped for Linux. Run client/setup.ps1 on the Windows client or client/setup-macos.sh on the macOS client.
Client|macOS|run|client/setup-macos.sh|Runs on the macOS client with the connection code from the host.
Client|Windows|run|client/setup.ps1|Runs on the Windows client with the connection code from the host.'

resolve_role_os() {
  # Prints "Kind|Path" for a Role/Os pair. Returns 1 when the pair is unknown.
  local want r o k p _m
  want="$1|$2"
  while IFS='|' read -r r o k p _m; do
    [ -z "$r" ] && continue
    if [ "$r|$o" = "$want" ]; then
      printf '%s|%s\n' "$k" "$p"
      return 0
    fi
  done <<EOF
$MATRIX
EOF
  return 1
}

detect_local_os() {
  case "$(uname -s 2>/dev/null)" in
    Linux) echo "Linux" ;;
    Darwin) echo "macOS" ;;
    *) echo "unknown" ;;
  esac
}

LOCAL_OS="$(detect_local_os)"
if [ "$LOCAL_OS" = "unknown" ]; then
  echo "Unsupported operating system: $(uname -s 2>/dev/null)"
  echo "This app runs on Linux and macOS. On Windows use app/Herdr-Setup.cmd."
  exit 2
fi

machine_for() {
  case "$1" in
    host/provision.sh) echo "the Linux or macOS host" ;;
    client/setup.ps1) echo "the Windows client" ;;
    client/setup-macos.sh) echo "the macOS client" ;;
    *) echo "the right machine" ;;
  esac
}

command_for() {
  # $1 is a path relative to the package root. The code is always masked.
  case "$1" in
    *.ps1) printf 'powershell -NoProfile -ExecutionPolicy Bypass -File "%s/%s" -ConnectionCode <code>\n' "$PKG_ROOT" "$1" ;;
    client/setup-macos.sh) printf 'bash "%s/%s" --code "<code>"\n' "$PKG_ROOT" "$1" ;;
    *) printf 'bash "%s/%s"\n' "$PKG_ROOT" "$1" ;;
  esac
}

show_target() {
  echo "Run this on $(machine_for "$1"):"
  echo "  file:    $PKG_ROOT/$1"
  echo "  command: $(command_for "$1")"
}

selftest() {
  local problems rows r o k p _m n f tsk
  problems=""

  if [ ! -r "$PKG_ROOT/VERSION" ]; then
    problems="$problems
VERSION file missing or unreadable"
  fi

  rows="$(printf '%s\n' "$MATRIX" | grep -c '^[A-Za-z][A-Za-z]*|')"
  if [ "$rows" -ne 6 ]; then
    problems="$problems
matrix has $rows rows, expected 6"
  fi

  n=0
  while IFS='|' read -r r o k p _m; do
    [ -z "$r" ] && continue
    if [ "$k" = "run" ]; then
      if [ ! -f "$PKG_ROOT/$p" ]; then
        problems="$problems
runnable script missing: $p"
      else
        case "$p" in
          *.sh)
            if ! bash -n "$PKG_ROOT/$p" >/dev/null 2>&1; then
              problems="$problems
bash -n failed: $p"
            fi
            ;;
        esac
      fi
      if [ "$o" = "$LOCAL_OS" ]; then n=$((n + 1)); fi
    fi
  done <<EOF
$MATRIX
EOF

  # No key material may be pasted into the front end.
  tsk='tskey'
  for f in "$APP_DIR"/*; do
    [ -f "$f" ] || continue
    if grep -q -F -- "$tsk-" "$f" 2>/dev/null; then
      problems="$problems
secret-like literal in app/$(basename "$f")"
    fi
  done

  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | sed '/^$/d; s/^/SELFTEST FAIL: /'
    exit 6
  fi

  printf 'SELFTEST OK (v%s; 6 combos; %s runnable here)\n' "$VERSION" "$n"
  exit 0
}

usage() {
  echo "Herdr Remote Setup v$VERSION"
  echo ""
  echo "Usage: herdr-setup.sh [--role Host|Client] [--os Linux|macOS|Windows] [--code CODE]"
  echo "                      [--dry-run] [--self-test] [--no-pause]"
  echo ""
  echo "Without --role/--os the script asks with a numbered menu."
  echo "The connection code is read without echo when it is needed."
}

ROLE=""
OS_SEL=""
CODE=""
DRY_RUN=0
NO_PAUSE=0
MODE="menu"

while [ $# -gt 0 ]; do
  case "$1" in
    --role|--os|--code)
      opt="$1"
      if [ $# -lt 2 ]; then
        echo "Missing value for $opt" >&2
        exit 2
      fi
      val="$2"
      case "$opt" in
        --role) ROLE="$val" ;;
        --os) OS_SEL="$val" ;;
        --code) CODE="$val" ;;
      esac
      shift 2
      ;;
    --role=*) ROLE="${1#--role=}"; shift ;;
    --os=*) OS_SEL="${1#--os=}"; shift ;;
    --code=*) CODE="${1#--code=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-pause) NO_PAUSE=1; shift ;;
    --self-test) MODE="selftest"; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

case "$ROLE" in
  Host|host) ROLE="Host" ;;
  Client|client) ROLE="Client" ;;
  "") ;;
  *) echo "Invalid --role: $ROLE (use Host or Client)" >&2; exit 2 ;;
esac

case "$OS_SEL" in
  Linux|linux) OS_SEL="Linux" ;;
  macOS|macos|MacOS|Macos) OS_SEL="macOS" ;;
  Windows|windows) OS_SEL="Windows" ;;
  "") ;;
  *) echo "Invalid --os: $OS_SEL (use Linux, macOS or Windows)" >&2; exit 2 ;;
esac

if [ "$MODE" = "selftest" ]; then
  selftest
fi

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
if [ -z "$ROLE" ]; then
  if [ ! -t 0 ]; then
    echo "No terminal for the menu. Pass --role Host|Client and --os Linux|macOS|Windows." >&2
    exit 2
  fi
  printf 'Herdr Remote Setup v%s\n\n' "$VERSION"
  printf 'Role:\n  1) Host\n  2) Client\n'
  printf 'Choice [1]: '
  read -r ans
  case "$ans" in
    2) ROLE="Client" ;;
    *) ROLE="Host" ;;
  esac
fi

if [ -z "$OS_SEL" ]; then
  if [ ! -t 0 ]; then
    echo "No terminal for the menu. Pass --os Linux|macOS|Windows." >&2
    exit 2
  fi
  case "$LOCAL_OS" in
    Linux) default_num="1" ;;
    macOS) default_num="2" ;;
    *) default_num="3" ;;
  esac
  printf '\nOS:\n  1) Linux\n  2) macOS\n  3) Windows\n'
  printf 'Choice [%s]: ' "$default_num"
  read -r ans
  case "$ans" in
    1) OS_SEL="Linux" ;;
    2) OS_SEL="macOS" ;;
    3) OS_SEL="Windows" ;;
    "")
      case "$default_num" in
        1) OS_SEL="Linux" ;;
        2) OS_SEL="macOS" ;;
        *) OS_SEL="Windows" ;;
      esac
      ;;
    *) echo "Invalid choice: $ans" >&2; exit 2 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Resolve
# ---------------------------------------------------------------------------
if ! row="$(resolve_role_os "$ROLE" "$OS_SEL")"; then
  echo "Unknown combination: $ROLE + $OS_SEL" >&2
  exit 2
fi

KIND="${row%%|*}"
ROW_PATH="${row#*|}"

RUN_HERE=0
if [ "$KIND" = "run" ] && [ "$OS_SEL" = "$LOCAL_OS" ]; then
  RUN_HERE=1
fi

CMD=""
if [ -n "$ROW_PATH" ]; then
  CMD="$(command_for "$ROW_PATH")"
fi

print_guidance() {
  echo ""
  echo "Selected: $ROLE + $OS_SEL"
  echo "This machine: $LOCAL_OS"
  if [ "$KIND" = "unsupported" ]; then
    echo "This combination is not shipped. Nothing was started."
    echo ""
    if [ "$ROLE" = "Host" ]; then
      show_target "host/provision.sh"
    else
      show_target "client/setup.ps1"
      show_target "client/setup-macos.sh"
    fi
  else
    echo "This flow only runs on the machine it belongs to. Nothing was started."
    echo ""
    show_target "$ROW_PATH"
  fi
}

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$RUN_HERE" -eq 1 ]; then
    echo "Selected: $ROLE + $OS_SEL (this machine: $LOCAL_OS)"
    echo "Command: $CMD"
  else
    print_guidance
  fi
  exit 0
fi

if [ "$KIND" = "unsupported" ]; then
  print_guidance
  exit 2
fi

if [ "$RUN_HERE" -ne 1 ]; then
  print_guidance
  exit 2
fi

# Ask for the secret only when the client flow will really run here.
if [ "$ROLE" = "Client" ] && [ -z "$CODE" ]; then
  printf 'Connection code: '
  read -r -s CODE
  printf '\n'
fi

if [ "$ROLE" = "Client" ] && [ -z "$CODE" ]; then
  echo "A connection code is required for the client flow (--code or the prompt)." >&2
  exit 2
fi

case "$ROW_PATH" in
  *.ps1)
    echo "This front end cannot start a Windows script on $LOCAL_OS." >&2
    exit 2
    ;;
esac

if [ ! -f "$PKG_ROOT/$ROW_PATH" ]; then
  echo "Missing script: $PKG_ROOT/$ROW_PATH" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Run the verified script with bash, so a missing execute bit is not a problem.
# ---------------------------------------------------------------------------
echo ""
echo "Running: $CMD"

if [ "$ROLE" = "Client" ]; then
  bash "$PKG_ROOT/$ROW_PATH" --code "$CODE"
else
  bash "$PKG_ROOT/$ROW_PATH"
fi
RC=$?

if [ "$NO_PAUSE" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
  printf '\nPress Enter to close'
  read -r _
fi

exit "$RC"
