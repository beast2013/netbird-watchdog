#!/usr/bin/env bash
# =============================================================================
# install.sh — installs netbird-watchdog on the local system
# Run as root: sudo bash install.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DEST="/usr/local/bin/netbird-watchdog.sh"
UNIT_DEST="/etc/systemd/system/netbird-watchdog.service"

# ── Colour helpers ────────────────────────────────────────────────────────────
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { red "Please run as root: sudo bash install.sh"; exit 1; }

# ── Prompt for configuration ──────────────────────────────────────────────────
echo ""
yellow "=== netbird-watchdog installer ==="
echo ""

read -rp "Netbird interface name        [wt0]:           " NB_IFACE
read -rp "Failsafe domain to resolve    [required]:      " NB_DOMAIN
read -rp "SSH port                      [22]:            " NB_PORT
read -rp "Firewall backend (auto/ufw/iptables) [auto]:  " NB_FIREWALL
read -rp "Grace period in seconds       [120]:           " NB_GRACE
read -rp "Check interval in seconds     [30]:            " NB_INTERVAL

NB_IFACE="${NB_IFACE:-wt0}"
NB_DOMAIN="${NB_DOMAIN:-}"
NB_PORT="${NB_PORT:-22}"
NB_FIREWALL="${NB_FIREWALL:-auto}"
NB_GRACE="${NB_GRACE:-120}"
NB_INTERVAL="${NB_INTERVAL:-30}"

if [[ -z "$NB_DOMAIN" ]]; then
    red "FAILSAFE_DOMAIN is required — aborting"
    exit 1
fi

case "$NB_FIREWALL" in
    auto|ufw|iptables) ;;
    *) red "Invalid firewall value '${NB_FIREWALL}' — must be auto, ufw, or iptables"; exit 1 ;;
esac

echo ""
green "Configuration:"
echo "  NETBIRD_IFACE   = $NB_IFACE"
echo "  FAILSAFE_DOMAIN = $NB_DOMAIN"
echo "  SSH_PORT        = $NB_PORT"
echo "  FIREWALL        = $NB_FIREWALL"
echo "  GRACE_PERIOD    = ${NB_GRACE}s"
echo "  CHECK_INTERVAL  = ${NB_INTERVAL}s"
echo ""
read -rp "Install with these settings? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { yellow "Aborted."; exit 0; }

# ── Install script ────────────────────────────────────────────────────────────
echo ""
echo "→ Installing script to $SCRIPT_DEST"
install -m 750 "$SCRIPT_DIR/netbird-watchdog.sh" "$SCRIPT_DEST"

# ── Install and configure systemd unit ───────────────────────────────────────
echo "→ Installing systemd unit to $UNIT_DEST"
cp "$SCRIPT_DIR/netbird-watchdog.service" "$UNIT_DEST"

# Substitute configuration values in the unit file
sed -i \
    -e "s|^Environment=NETBIRD_IFACE=.*|Environment=NETBIRD_IFACE=${NB_IFACE}|" \
    -e "s|^Environment=FAILSAFE_DOMAIN=.*|Environment=FAILSAFE_DOMAIN=${NB_DOMAIN}|" \
    -e "s|^Environment=SSH_PORT=.*|Environment=SSH_PORT=${NB_PORT}|" \
    -e "s|^Environment=FIREWALL=.*|Environment=FIREWALL=${NB_FIREWALL}|" \
    -e "s|^Environment=GRACE_PERIOD=.*|Environment=GRACE_PERIOD=${NB_GRACE}|" \
    -e "s|^Environment=CHECK_INTERVAL=.*|Environment=CHECK_INTERVAL=${NB_INTERVAL}|" \
    "$UNIT_DEST"

# ── Enable and start ──────────────────────────────────────────────────────────
echo "→ Reloading systemd daemon"
systemctl daemon-reload

echo "→ Enabling service"
systemctl enable netbird-watchdog.service

echo "→ Starting service"
systemctl start netbird-watchdog.service

echo ""
green "✓ netbird-watchdog installed and running"
echo ""
echo "Useful commands:"
echo "  systemctl status netbird-watchdog"
echo "  journalctl -u netbird-watchdog -f"
echo "  systemctl stop netbird-watchdog"
echo ""
yellow "Remember: sshd_config.d/ drop-ins require OpenSSH 7.3+."
yellow "The drop-in will be placed at: /etc/ssh/sshd_config.d/99-netbird-watchdog.conf"
