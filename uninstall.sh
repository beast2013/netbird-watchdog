#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — removes netbird-watchdog from the local system
# Run as root: sudo bash uninstall.sh
# =============================================================================
set -uo pipefail

SCRIPT_DEST="/usr/local/bin/netbird-watchdog.sh"
UNIT_DEST="/etc/systemd/system/netbird-watchdog.service"
SSHD_DROP_IN="/etc/ssh/sshd_config.d/99-netbird-watchdog.conf"
STATE_DIR="/run/netbird-watchdog"
FAILSAFE_IP_FILE="${STATE_DIR}/failsafe_ip"
FIREWALL_BACKEND_FILE="${STATE_DIR}/firewall_backend"

# ── Colour helpers ────────────────────────────────────────────────────────────
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n'    "$*"; }

step()   { echo "→ $*"; }
ok()     { green "  ✓ $*"; }
skip()   { dim   "  – $*"; }
warn()   { yellow "  ⚠ $*"; }
fail()   { red   "  ✗ $*"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { red "Please run as root: sudo bash uninstall.sh"; exit 1; }

echo ""
yellow "=== netbird-watchdog uninstaller ==="
echo ""

# ── Read current state from live system ───────────────────────────────────────
CURRENT_STATE=""
SAVED_IP=""
SAVED_BACKEND=""
SSH_PORT=""

# Pull SSH port from the installed unit before we remove it
if [[ -f "$UNIT_DEST" ]]; then
    SSH_PORT=$(grep -Po '(?<=Environment=SSH_PORT=)\S+' "$UNIT_DEST" 2>/dev/null || true)
fi
SSH_PORT="${SSH_PORT:-22}"

[[ -f "${STATE_DIR}/state"  ]] && CURRENT_STATE=$(cat "${STATE_DIR}/state"  2>/dev/null || true)
[[ -f "$FAILSAFE_IP_FILE"   ]] && SAVED_IP=$(cat       "$FAILSAFE_IP_FILE"  2>/dev/null || true)
[[ -f "$FIREWALL_BACKEND_FILE" ]] && SAVED_BACKEND=$(cat "$FIREWALL_BACKEND_FILE" 2>/dev/null || true)

# ── Warn if currently in failsafe ─────────────────────────────────────────────
if [[ "$CURRENT_STATE" == "failsafe" ]]; then
    echo ""
    yellow "  ┌─────────────────────────────────────────────────────────────┐"
    yellow "  │  WARNING: netbird-watchdog is currently in FAILSAFE state.  │"
    yellow "  │  SSH is bound to 0.0.0.0 and a firewall rule is active.     │"
    yellow "  │  This script will clean up both before uninstalling.        │"
    yellow "  └─────────────────────────────────────────────────────────────┘"
    echo ""
fi

# ── Confirmation ──────────────────────────────────────────────────────────────
echo "This will remove:"
echo "  • netbird-watchdog systemd service (stopped + disabled)"
echo "  • ${SCRIPT_DEST}"
echo "  • ${UNIT_DEST}"
if [[ -f "$SSHD_DROP_IN" ]]; then
echo "  • ${SSHD_DROP_IN}  (failsafe drop-in — will reload sshd)"
fi
if [[ -n "$SAVED_IP" && -n "$SAVED_BACKEND" ]]; then
echo "  • Firewall rule for ${SAVED_IP} port ${SSH_PORT} (${SAVED_BACKEND})"
fi
echo ""
read -rp "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { yellow "Aborted."; exit 0; }
echo ""

# ── Stop and disable service ───────────────────────────────────────────────────
step "Stopping netbird-watchdog service"
if systemctl is-active --quiet netbird-watchdog 2>/dev/null; then
    systemctl stop netbird-watchdog && ok "Service stopped" || fail "Could not stop service"
else
    skip "Service was not running"
fi

step "Disabling netbird-watchdog service"
if systemctl is-enabled --quiet netbird-watchdog 2>/dev/null; then
    systemctl disable netbird-watchdog && ok "Service disabled" || fail "Could not disable service"
else
    skip "Service was not enabled"
fi

# ── Remove sshd drop-in ───────────────────────────────────────────────────────
step "Removing sshd drop-in"
if [[ -f "$SSHD_DROP_IN" ]]; then
    rm -f "$SSHD_DROP_IN" && ok "Removed ${SSHD_DROP_IN}" || fail "Could not remove ${SSHD_DROP_IN}"

    # Reload sshd so it stops listening on 0.0.0.0
    SSHD_UNIT=""
    if systemctl list-units --type=service --all --no-legend 2>/dev/null \
            | awk '{print $1}' | grep -qx 'sshd.service'; then
        SSHD_UNIT="sshd"
    elif systemctl list-units --type=service --all --no-legend 2>/dev/null \
            | awk '{print $1}' | grep -qx 'ssh.service'; then
        SSHD_UNIT="ssh"
    fi

    if [[ -n "$SSHD_UNIT" ]]; then
        systemctl reload "$SSHD_UNIT" \
            && ok "sshd reloaded — ListenAddress restored to default" \
            || fail "sshd reload failed — you may need to run: systemctl reload ${SSHD_UNIT}"
    else
        warn "Could not find sshd/ssh unit — reload it manually: systemctl reload ssh"
    fi
else
    skip "No sshd drop-in present"
fi

# ── Remove firewall rule ───────────────────────────────────────────────────────
step "Removing firewall rule"
if [[ -n "$SAVED_IP" && -n "$SAVED_BACKEND" ]]; then
    case "$SAVED_BACKEND" in
        ufw)
            if ufw status | grep -qF "$SAVED_IP" 2>/dev/null; then
                ufw --force delete allow from "$SAVED_IP" to any port "$SSH_PORT" proto tcp \
                    && ok "UFW rule removed for ${SAVED_IP}:${SSH_PORT}" \
                    || fail "Could not remove UFW rule — run: ufw delete allow from ${SAVED_IP} to any port ${SSH_PORT} proto tcp"
            else
                skip "UFW rule for ${SAVED_IP} not found — already removed"
            fi
            ;;
        iptables)
            if iptables -C INPUT -s "$SAVED_IP" -p tcp --dport "$SSH_PORT" -j ACCEPT -m comment --comment "netbird-watchdog" 2>/dev/null; then
                iptables -D INPUT -s "$SAVED_IP" -p tcp --dport "$SSH_PORT" -j ACCEPT \
                    -m comment --comment "netbird-watchdog" \
                    && ok "iptables rule removed for ${SAVED_IP}:${SSH_PORT}" \
                    || fail "Could not remove iptables rule — run: iptables -D INPUT -s ${SAVED_IP} -p tcp --dport ${SSH_PORT} -j ACCEPT"
            else
                skip "iptables rule for ${SAVED_IP} not found — already removed"
            fi
            ;;
        *)
            warn "Unknown firewall backend '${SAVED_BACKEND}' — cannot remove rule automatically"
            warn "Check manually: ufw status numbered  or  iptables -L INPUT -n --line-numbers"
            ;;
    esac
elif [[ -n "$SAVED_IP" && -z "$SAVED_BACKEND" ]]; then
    warn "Saved IP found (${SAVED_IP}) but no firewall backend recorded"
    warn "Remove the rule manually:"
    warn "  ufw:      ufw status numbered  →  ufw delete <n>"
    warn "  iptables: iptables -L INPUT -n --line-numbers  →  iptables -D INPUT <n>"
else
    skip "No saved failsafe IP — no firewall rule to remove"
fi

# ── Remove installed files ────────────────────────────────────────────────────
step "Removing installed files"
if [[ -f "$SCRIPT_DEST" ]]; then
    rm -f "$SCRIPT_DEST" && ok "Removed ${SCRIPT_DEST}" || fail "Could not remove ${SCRIPT_DEST}"
else
    skip "${SCRIPT_DEST} not found"
fi

if [[ -f "$UNIT_DEST" ]]; then
    rm -f "$UNIT_DEST" && ok "Removed ${UNIT_DEST}" || fail "Could not remove ${UNIT_DEST}"
else
    skip "${UNIT_DEST} not found"
fi

# ── Reload systemd ────────────────────────────────────────────────────────────
step "Reloading systemd daemon"
systemctl daemon-reload && ok "systemd daemon reloaded" || fail "systemd daemon-reload failed"

# ── State dir note (ephemeral — no action needed) ─────────────────────────────
if [[ -d "$STATE_DIR" ]]; then
    skip "${STATE_DIR} is ephemeral (tmpfs) — will be gone after next reboot"
fi

echo ""
green "✓ netbird-watchdog has been uninstalled"
echo ""
