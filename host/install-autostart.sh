#!/usr/bin/env bash
# Install a systemd unit that keeps the Tailscale node usable after a reboot
# or a re-registration.
#
# Why: if the VM loses /var/lib/tailscale (image rebuild, ephemeral disk),
# the node re-registers with a new node key and a new device ID. Without
# re-applying the tag and --ssh, ACL rules stop matching and Tailscale SSH
# stops working. This unit re-asserts them at boot.

set -u

VERSION="$(cat "$(dirname "$0")/../VERSION" 2>/dev/null || echo "0.0.0")"
ENV_DIR="/etc/herdr-setup"
ENV_FILE="$ENV_DIR/tailscale.env"
UNIT="/etc/systemd/system/herdr-tailscale-ssh.service"

usage() {
  cat <<EOF
Herdr Remote Setup - install autostart (v$VERSION)

Usage:
  sudo ./install-autostart.sh --authkey <tskey-...> [--tag tag:herdr-host] [--no-ssh]

Writes:
  $ENV_FILE    (root 600)   auth key, tag, ssh flag
  $UNIT                     oneshot unit, runs after tailscaled

The unit is idempotent: it only runs 'tailscale up' when the node is logged
out, when --ssh is not enabled, or when the tag is missing.
EOF
}

AUTHKEY=""; TAG=""; WANT_SSH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --authkey)  AUTHKEY="${2:-}"; shift 2 ;;
    --authkey=*) AUTHKEY="${1#--authkey=}"; shift ;;
    --tag)      TAG="${2:-}"; shift 2 ;;
    --tag=*)    TAG="${1#--tag=}"; shift ;;
    --no-ssh)   WANT_SSH=0; shift ;;
    --help|-h)  usage; exit 0 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 2; }
[ -n "$AUTHKEY" ] || { echo "missing --authkey"; usage; exit 2; }
case "$AUTHKEY" in tskey-*) : ;; *) echo "auth key must start with tskey-"; exit 2 ;; esac
if [ -n "$TAG" ]; then case "$TAG" in tag:*) : ;; *) echo "tag must start with tag:"; exit 2 ;; esac; fi

TS_EXE="$(command -v tailscale 2>/dev/null || echo /usr/bin/tailscale)"

mkdir -p "$ENV_DIR"
umask 077
cat > "$ENV_FILE" <<EOF
# Herdr Remote Setup - Tailscale environment (v$VERSION)
TS_AUTHKEY=$AUTHKEY
TS_TAG=$TAG
TS_SSH=$WANT_SSH
TS_EXE=$TS_EXE
EOF
chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE" 2>/dev/null || true

cat > "$UNIT" <<'EOF'
[Unit]
Description=Herdr: re-assert Tailscale identity, tag, and SSH after boot
After=tailscaled.service network-online.target
Wants=tailscaled.service
ConditionPathExists=/etc/herdr-setup/tailscale.env

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/herdr-setup/tailscale.env
ExecStart=/bin/sh -c '\
  set -u; \
  TS="${TS_EXE:-/usr/bin/tailscale}"; \
  [ -x "$TS" ] || TS=/usr/bin/tailscale; \
  state="$("$TS" status --json 2>/dev/null | tr "," "\n" | grep -i backendstate | head -1)"; \
  need_up=0; \
  echo "$state" | grep -qi "Running" || need_up=1; \
  "$TS" debug prefs 2>/dev/null | grep -q '"RunSSH":[[:space:]]*true" || \
    "$TS" status --json 2>/dev/null | tr "," "\n" | grep -qi "sshhostkeys" || need_up=1; \
  if [ -n "${TS_TAG:-}" ]; then \
    "$TS" status --json 2>/dev/null | grep -q "${TS_TAG}" || need_up=1; \
  fi; \
  if [ "$need_up" = "1" ]; then \
    flag=""; [ "${TS_SSH:-1}" = "1" ] && flag="--ssh"; \
    echo "re-asserting tailscale identity"; \
    "$TS" up --authkey="${TS_AUTHKEY}" ${TS_TAG:+--advertise-tags="${TS_TAG}"} $flag --accept-routes=false || \
      echo "tailscale up failed"; \
  else \
    echo "tailscale identity already correct"; \
  fi'

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$UNIT"

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable herdr-tailscale-ssh.service >/dev/null 2>&1 || true

echo "Installed: $ENV_FILE (600)"
echo "Installed: $UNIT"
echo "Enabled:   herdr-tailscale-ssh.service"
echo ""
echo "Test now:  sudo systemctl start herdr-tailscale-ssh.service && systemctl status herdr-tailscale-ssh.service --no-pager"
echo "Note: the auth key is stored on disk (root only). Rotate it if it leaks."
