#!/usr/bin/env bash
# =============================================================================
# netbird-watchdog.sh
# Monitors the Netbird interface and activates an SSH failsafe when the VPN
# has been down longer than the configured grace period.
#
# Failsafe ON:  ListenAddress 0.0.0.0 + firewall rule allowing SSH from
#               the resolved FAILSAFE_DOMAIN IP
# Failsafe OFF: Drop-in removed, firewall rule deleted, sshd reloaded
#
# Firewall backends: ufw, iptables (set FIREWALL=auto to detect at startup)
# =============================================================================

set -uo pipefail

# ── Configuration (override via systemd Environment= or export before running)
NETBIRD_IFACE="${NETBIRD_IFACE:-wt0}"
FAILSAFE_DOMAIN="${FAILSAFE_DOMAIN:-yourdomain.example.com}"
SSH_PORT="${SSH_PORT:-22}"
FIREWALL="${FIREWALL:-auto}"               # auto, ufw, or iptables
GRACE_PERIOD="${GRACE_PERIOD:-120}"        # seconds down before triggering failsafe
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"     # seconds between checks

# ── Internal paths
STATE_DIR="/run/netbird-watchdog"
STATE_FILE="${STATE_DIR}/state"
FAILSAFE_IP_FILE="${STATE_DIR}/failsafe_ip"
FIREWALL_BACKEND_FILE="${STATE_DIR}/firewall_backend"  # backend used at activation
SSHD_DROP_IN="/etc/ssh/sshd_config.d/99-netbird-watchdog.conf"
LOG_TAG="netbird-watchdog"

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { logger -t "$LOG_TAG" -- "$*";         echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*"; }
warn() { logger -t "$LOG_TAG" -- "WARN: $*";   echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN]  $*"; }
err()  { logger -t "$LOG_TAG" -- "ERROR: $*";  echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2; }

# ── State helpers ─────────────────────────────────────────────────────────────
get_state() { cat "$STATE_FILE" 2>/dev/null || echo "normal"; }
set_state() { echo "$1" > "$STATE_FILE"; }

# ── Network helpers ───────────────────────────────────────────────────────────

# Returns 0 if the Netbird interface exists and is operationally up
iface_up() {
    local state
    state=$(cat "/sys/class/net/${NETBIRD_IFACE}/operstate" 2>/dev/null) || return 1
    [[ "$state" == "up" ]]
}

# Resolves FAILSAFE_DOMAIN to its first IPv4 address; prints it or returns 1
resolve_domain() {
    local ip
    ip=$(getent hosts "$FAILSAFE_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z "$ip" ]]; then
        err "DNS resolution failed for '$FAILSAFE_DOMAIN'"
        return 1
    fi
    echo "$ip"
}

# ── sshd helpers ──────────────────────────────────────────────────────────────

# Prints the active systemd unit name for sshd (ssh on Debian/Ubuntu, sshd on RHEL)
sshd_unit() {
    if systemctl list-units --type=service --all --no-legend 2>/dev/null \
            | awk '{print $1}' | grep -qx 'sshd.service'; then
        echo "sshd"
    elif systemctl list-units --type=service --all --no-legend 2>/dev/null \
            | awk '{print $1}' | grep -qx 'ssh.service'; then
        echo "ssh"
    else
        err "Cannot find sshd or ssh systemd unit"
        return 1
    fi
}

reload_sshd() {
    local unit
    unit=$(sshd_unit) || return 1
    systemctl reload "$unit"
}

restart_sshd() {
    local unit
    unit=$(sshd_unit) || return 1
    log "SSH health: restarting ${unit}.service"
    systemctl restart "$unit"
}

# Returns 0 if SSH is listening on SSH_PORT.
# In failsafe state also verifies it is bound to 0.0.0.0 specifically.
ssh_listening() {
    local current_state="${1:-normal}"

    # ss output example:  LISTEN  0  128  0.0.0.0:22  0.0.0.0:*
    local listeners
    listeners=$(ss -tlnH "sport = :${SSH_PORT}" 2>/dev/null)

    if [[ -z "$listeners" ]]; then
        return 1   # nothing at all on this port
    fi

    if [[ "$current_state" == "failsafe" ]]; then
        # Must have a wildcard/any-address binding when in failsafe
        echo "$listeners" | grep -qE '(0\.0\.0\.0|::|\*):'"${SSH_PORT}"
    else
        return 0   # any listener on the port is fine in normal state
    fi
}

# Checks that sshd is active and listening on the expected address/port.
# On failure: restarts sshd, waits briefly, and checks once more.
# Called at the end of every main-loop iteration, before sleep.
check_ssh_health() {
    local current_state="${1:-normal}"
    local unit

    unit=$(sshd_unit) || {
        warn "SSH health: cannot determine sshd unit name — skipping check"
        return
    }

    local svc_ok=0 listen_ok=0

    systemctl is-active --quiet "${unit}.service" 2>/dev/null && svc_ok=1
    ssh_listening "$current_state"                             && listen_ok=1

    if [[ "$svc_ok" -eq 1 && "$listen_ok" -eq 1 ]]; then
        return 0   # all good
    fi

    # ── Something is wrong — log what and attempt recovery ───────────────────
    if [[ "$svc_ok" -eq 0 ]]; then
        warn "SSH health: ${unit}.service is NOT active"
    fi
    if [[ "$listen_ok" -eq 0 ]]; then
        if [[ "$current_state" == "failsafe" ]]; then
            warn "SSH health: not listening on 0.0.0.0:${SSH_PORT} (failsafe mode)"
        else
            warn "SSH health: not listening on port ${SSH_PORT}"
        fi
    fi

    restart_sshd || { err "SSH health: restart command failed"; return 1; }

    # Give sshd up to 5 s to bind its socket after restart
    local waited=0
    while [[ "$waited" -lt 5 ]]; do
        sleep 1
        (( waited++ ))
        if systemctl is-active --quiet "${unit}.service" 2>/dev/null \
                && ssh_listening "$current_state"; then
            log "SSH health: recovered after restart (${waited}s)"
            return 0
        fi
    done

    err "SSH health: still not healthy after restart — will retry next cycle"
    return 1
}

write_sshd_dropin() {
    mkdir -p "$(dirname "$SSHD_DROP_IN")"
    cat > "$SSHD_DROP_IN" <<EOF
# -------------------------------------------------------
# Managed by netbird-watchdog — DO NOT EDIT MANUALLY
# Activated: $(date -Iseconds)
# Netbird interface '${NETBIRD_IFACE}' was unreachable for
# more than ${GRACE_PERIOD} seconds.
# -------------------------------------------------------
ListenAddress 0.0.0.0
EOF
}

remove_sshd_dropin() {
    if [[ -f "$SSHD_DROP_IN" ]]; then
        rm -f "$SSHD_DROP_IN"
        return 0
    fi
    return 1
}

# ── Firewall abstraction ───────────────────────────────────────────────────────

# Resolves FIREWALL=auto to 'ufw' or 'iptables' and prints the result.
# Prefers ufw if it is installed and actively enabled; falls back to iptables.
detect_firewall() {
    if [[ "$FIREWALL" != "auto" ]]; then
        echo "$FIREWALL"
        return 0
    fi
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
        echo "ufw"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        err "FIREWALL=auto: cannot find ufw (active) or iptables — install one of them"
        return 1
    fi
}

# ── UFW backend ────────────────────────────────────────────────────────────────

_ufw_rule_exists() {
    local ip="$1"
    ufw status | grep -qF "$ip"
}

_ufw_add() {
    local ip="$1"
    if _ufw_rule_exists "$ip"; then
        log "UFW: rule for $ip already present — skipping add"
    else
        ufw --force allow from "$ip" to any port "$SSH_PORT" proto tcp \
            comment "netbird-watchdog"
        log "UFW: added allow ssh from $ip"
    fi
}

_ufw_delete() {
    local ip="$1"
    if _ufw_rule_exists "$ip"; then
        ufw --force delete allow from "$ip" to any port "$SSH_PORT" proto tcp
        log "UFW: removed allow ssh rule for $ip"
    else
        warn "UFW: rule for $ip not found — nothing to delete"
    fi
}

# ── iptables backend ───────────────────────────────────────────────────────────

_ipt_rule_exists() {
    local ip="$1"
    iptables -C INPUT -s "$ip" -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null
}

_ipt_add() {
    local ip="$1"
    if _ipt_rule_exists "$ip"; then
        log "iptables: rule for $ip already present — skipping add"
    else
        # Insert at position 1 so it takes effect before any DROP rules
        iptables -I INPUT 1 -s "$ip" -p tcp --dport "$SSH_PORT" -j ACCEPT \
            -m comment --comment "netbird-watchdog"
        log "iptables: inserted allow ssh from $ip at INPUT pos 1"
    fi
}

_ipt_delete() {
    local ip="$1"
    if _ipt_rule_exists "$ip"; then
        iptables -D INPUT -s "$ip" -p tcp --dport "$SSH_PORT" -j ACCEPT \
            -m comment --comment "netbird-watchdog"
        log "iptables: removed allow ssh rule for $ip"
    else
        warn "iptables: rule for $ip not found — nothing to delete"
    fi
}

# ── Generic firewall interface ─────────────────────────────────────────────────

# add_firewall_rule <ip> <backend>
add_firewall_rule() {
    local ip="$1" backend="$2"
    case "$backend" in
        ufw)      _ufw_add      "$ip" ;;
        iptables) _ipt_add      "$ip" ;;
        *) err "Unknown firewall backend '${backend}'"; return 1 ;;
    esac
}

# delete_firewall_rule <ip> <backend>
delete_firewall_rule() {
    local ip="$1" backend="$2"
    case "$backend" in
        ufw)      _ufw_delete   "$ip" ;;
        iptables) _ipt_delete   "$ip" ;;
        *) err "Unknown firewall backend '${backend}'"; return 1 ;;
    esac
}

# ── Failsafe ON ───────────────────────────────────────────────────────────────
activate_failsafe() {
    log "=== ACTIVATING FAILSAFE ==="

    local resolved_ip
    if ! resolved_ip=$(resolve_domain); then
        err "Cannot activate failsafe without a resolvable domain — will retry next cycle"
        return 1
    fi

    local backend
    if ! backend=$(detect_firewall); then
        err "Cannot activate failsafe without a working firewall backend — will retry next cycle"
        return 1
    fi

    log "Resolved ${FAILSAFE_DOMAIN} → ${resolved_ip} | firewall backend: ${backend}"

    # 1. Write sshd drop-in and reload
    write_sshd_dropin
    if reload_sshd; then
        log "sshd reloaded with ListenAddress 0.0.0.0"
    else
        err "sshd reload failed — rolling back drop-in"
        remove_sshd_dropin
        return 1
    fi

    # 2. Add firewall rule
    add_firewall_rule "$resolved_ip" "$backend"

    # 3. Persist state (save backend so restore uses the same one)
    echo "$resolved_ip" > "$FAILSAFE_IP_FILE"
    echo "$backend"     > "$FIREWALL_BACKEND_FILE"
    set_state "failsafe"

    log "=== FAILSAFE ACTIVE: SSH open on 0.0.0.0:${SSH_PORT}, allowed from ${resolved_ip} (${backend}) ==="
}

# ── Failsafe OFF ──────────────────────────────────────────────────────────────
restore_normal() {
    log "=== Netbird recovered — RESTORING NORMAL CONFIGURATION ==="

    local saved_ip="" saved_backend=""
    [[ -f "$FAILSAFE_IP_FILE"       ]] && saved_ip=$(cat "$FAILSAFE_IP_FILE")
    [[ -f "$FIREWALL_BACKEND_FILE"  ]] && saved_backend=$(cat "$FIREWALL_BACKEND_FILE")

    # Fall back to current detection if backend file is missing
    if [[ -z "$saved_backend" ]]; then
        warn "No saved firewall backend — attempting auto-detect for cleanup"
        saved_backend=$(detect_firewall 2>/dev/null) || saved_backend=""
    fi

    # 1. Remove sshd drop-in and reload
    if remove_sshd_dropin; then
        if reload_sshd; then
            log "sshd reloaded — ListenAddress restored to default (Netbird IP)"
        else
            err "sshd reload failed after removing drop-in; config removed but daemon not refreshed"
        fi
    else
        log "No sshd drop-in found — nothing to remove"
    fi

    # 2. Remove firewall rule
    if [[ -n "$saved_ip" && -n "$saved_backend" ]]; then
        delete_firewall_rule "$saved_ip" "$saved_backend"
        rm -f "$FAILSAFE_IP_FILE" "$FIREWALL_BACKEND_FILE"
    elif [[ -n "$saved_ip" && -z "$saved_backend" ]]; then
        err "Cannot remove firewall rule for $saved_ip — no backend determined"
        warn "Remove manually: check 'ufw status numbered' or 'iptables -L INPUT --line-numbers'"
    else
        warn "No saved failsafe IP found — cannot remove firewall rule automatically"
        warn "Remove manually: check 'ufw status numbered' or 'iptables -L INPUT --line-numbers'"
    fi

    set_state "normal"
    log "=== NORMAL CONFIGURATION RESTORED ==="
}

# ── Preflight checks ──────────────────────────────────────────────────────────
preflight() {
    local ok=1

    [[ $EUID -eq 0 ]] || { err "Must run as root"; ok=0; }

    command -v getent    &>/dev/null || { err "'getent' not found in PATH";    ok=0; }
    command -v systemctl &>/dev/null || { err "'systemctl' not found in PATH"; ok=0; }
    command -v ss        &>/dev/null || { err "'ss' not found in PATH (install iproute2)"; ok=0; }

    case "$FIREWALL" in
        ufw)
            command -v ufw &>/dev/null || { err "'ufw' not found in PATH"; ok=0; }
            ;;
        iptables)
            command -v iptables &>/dev/null || { err "'iptables' not found in PATH"; ok=0; }
            ;;
        auto)
            if ! command -v ufw &>/dev/null && ! command -v iptables &>/dev/null; then
                err "FIREWALL=auto: neither 'ufw' nor 'iptables' found in PATH"
                ok=0
            fi
            ;;
        *)
            err "FIREWALL='${FIREWALL}' is invalid — must be: auto, ufw, or iptables"
            ok=0
            ;;
    esac

    if [[ "$FAILSAFE_DOMAIN" == "yourdomain.example.com" ]]; then
        err "FAILSAFE_DOMAIN is still the placeholder value — set it in the systemd unit"
        ok=0
    fi

    [[ "$ok" -eq 1 ]]
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    preflight || exit 1

    mkdir -p "$STATE_DIR"

    log "Started | iface=${NETBIRD_IFACE} domain=${FAILSAFE_DOMAIN} port=${SSH_PORT} firewall=${FIREWALL} grace=${GRACE_PERIOD}s interval=${CHECK_INTERVAL}s"

    # If we were in failsafe before a daemon restart, honour that state
    local current_state
    current_state=$(get_state)
    if [[ "$current_state" == "failsafe" ]]; then
        log "Resuming in FAILSAFE state from previous run"
    fi

    local down_since=0   # epoch timestamp when iface first went down (0 = not down)

    while true; do
        current_state=$(get_state)

        if iface_up; then
            # Interface is up
            if [[ "$down_since" -ne 0 ]]; then
                log "Netbird interface ${NETBIRD_IFACE} is back up"
                down_since=0
            fi
            if [[ "$current_state" == "failsafe" ]]; then
                restore_normal
            fi
        else
            # Interface is down
            local now
            now=$(date +%s)

            if [[ "$down_since" -eq 0 ]]; then
                down_since=$now
                log "Netbird interface ${NETBIRD_IFACE} is DOWN — grace period: ${GRACE_PERIOD}s"
            fi

            local elapsed=$(( now - down_since ))

            if [[ "$current_state" != "failsafe" ]]; then
                if [[ "$elapsed" -ge "$GRACE_PERIOD" ]]; then
                    log "Grace period exceeded (${elapsed}s ≥ ${GRACE_PERIOD}s) — triggering failsafe"
                    activate_failsafe
                else
                    log "Netbird DOWN for ${elapsed}s / ${GRACE_PERIOD}s grace period remaining"
                fi
            fi
        fi

        # ── SSH health check (runs every cycle regardless of Netbird state) ──
        check_ssh_health "$(get_state)"

        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
