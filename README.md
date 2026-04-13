# Netbird Watchdog

A lightweight systemd service that monitors your [Netbird](https://netbird.io) VPN interface and automatically activates an SSH failsafe if the VPN goes down for longer than a configurable grace period.

Supports **ufw** and **iptables** firewall backends, with automatic detection.

## How it works

Every cycle the watchdog does two things:

1. **Checks the Netbird interface** — if it has been down longer than the grace period, the failsafe is activated. When the interface recovers, the original configuration is restored.
2. **Checks SSH health** — regardless of VPN state, it verifies that `sshd` is active and listening on the correct address and port. If not, it restarts sshd and confirms recovery before moving on.

### Failsafe ON (Netbird down beyond grace period)

- Writes `/etc/ssh/sshd_config.d/99-netbird-watchdog.conf` with `ListenAddress 0.0.0.0`
- Reloads `sshd`
- Resolves the configured domain name and adds a firewall rule to allow SSH from the resolved IP
- Saves the resolved IP and the firewall backend used to `/run/netbird-watchdog/` for clean restoration

### Failsafe OFF (Netbird recovers)

- Removes the sshd drop-in and reloads `sshd`
- Deletes the firewall rule using the same backend that added it
- Restores normal state

---

## Requirements

| Dependency | Notes |
|---|---|
| `bash` | 4.0+ |
| `systemd` | For service management |
| `ufw` **or** `iptables` | At least one firewall tool must be present |
| `ss` | Socket inspection — part of `iproute2` |
| `getent` | DNS resolution — part of `libc-bin` |
| `logger` | Syslog — part of `util-linux` |
| OpenSSH | 7.3+ (required for `sshd_config.d/` drop-in support) |

All dependencies are present by default on Ubuntu Server 20.04 LTS and later.

> **iptables persistence note:** iptables rules are not saved across reboots by default. If you use the `iptables` backend, install `iptables-persistent` (`sudo apt install iptables-persistent`) to make rules survive a reboot. The watchdog re-adds its rule on the next failsafe activation regardless, but any gap between boot and Netbird coming online would not be covered by a persisted rule. In most cases the watchdog's grace period handles this automatically.

---

## Installation

```bash
git clone https://github.com/beast2013/netbird-watchdog.git
cd netbird-watchdog
sudo bash install.sh
```

The installer will prompt you for:

| Setting | Default | Description |
|---|---|---|
| `NETBIRD_IFACE` | `wt0` | Netbird network interface name |
| `FAILSAFE_DOMAIN` | *(required)* | Domain to resolve for the SSH allow rule |
| `SSH_PORT` | `22` | SSH port |
| `FIREWALL` | `auto` | Firewall backend: `auto`, `ufw`, or `iptables` |
| `GRACE_PERIOD` | `120` | Seconds the interface must be down before triggering the failsafe |
| `CHECK_INTERVAL` | `30` | Seconds between checks |

Settings are written into the systemd unit as `Environment=` variables. You can change them at any time by editing the unit file directly (see [Configuration](#configuration)).

---

## Firewall backends

### `auto` (default)

At startup and at each failsafe activation, the watchdog detects which backend to use:

1. If `ufw` is installed **and** `ufw status` reports `Status: active` → uses `ufw`
2. Otherwise, if `iptables` is available → uses `iptables`
3. If neither is found, the failsafe activation is deferred until the next cycle

The backend actually used is saved to `/run/netbird-watchdog/firewall_backend` at activation time, so the correct backend is always used for cleanup even if the detected value would differ on a later cycle.

### `ufw`

Adds and removes rules using `ufw allow from <ip> to any port <SSH_PORT> proto tcp`. Rules are tagged with the comment `netbird-watchdog`.

### `iptables`

Inserts a rule at `INPUT` position 1 using `iptables -I INPUT 1 -s <ip> -p tcp --dport <SSH_PORT> -j ACCEPT`. Inserting at position 1 ensures the rule takes effect before any `DROP` or `REJECT` rules lower in the chain. The rule is also tagged with the comment `netbird-watchdog`.

> **Note:** iptables rules are not persistent across reboots by default. See the [Requirements](#requirements) section for details.

---

## Configuration

The service is configured via environment variables in the systemd unit file:

```bash
sudo systemctl edit --full netbird-watchdog
```

```ini
Environment=NETBIRD_IFACE=wt0
Environment=FAILSAFE_DOMAIN=home.example.com
Environment=SSH_PORT=22
Environment=FIREWALL=auto
Environment=GRACE_PERIOD=120
Environment=CHECK_INTERVAL=30
```

After saving, reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart netbird-watchdog
```

### Finding your Netbird interface name

```bash
netbird status
# or
ip link show | grep wt
```

The default interface name is `wt0` but may differ depending on your Netbird version and configuration.

---

## Usage

### Service management

```bash
# Check current status
sudo systemctl status netbird-watchdog

# Follow live logs
sudo journalctl -u netbird-watchdog -f

# Stop / start / restart
sudo systemctl stop netbird-watchdog
sudo systemctl start netbird-watchdog
sudo systemctl restart netbird-watchdog
```

### Testing the failsafe

You can simulate a Netbird outage without actually disrupting your VPN by temporarily taking the interface down:

```bash
# Trigger the failsafe (interface down)
sudo ip link set wt0 down

# Watch it activate after the grace period
sudo journalctl -u netbird-watchdog -f

# Restore (watchdog will clean up automatically within one check cycle)
sudo ip link set wt0 up
```

### Checking failsafe state

```bash
# Current watchdog state (normal / failsafe)
cat /run/netbird-watchdog/state

# IP the firewall rule was added for
cat /run/netbird-watchdog/failsafe_ip

# Firewall backend used at activation
cat /run/netbird-watchdog/firewall_backend

# Confirm sshd drop-in is present during failsafe
cat /etc/ssh/sshd_config.d/99-netbird-watchdog.conf

# Confirm firewall rule is active
sudo ufw status                              # if using ufw
sudo iptables -L INPUT -n --line-numbers     # if using iptables
```

---

## How SSH health checking works

At the end of every check cycle the watchdog verifies two things:

1. `sshd`/`ssh` systemd unit is **active**
2. SSH is **listening on the correct address and port** (verified via `ss`)
   - In **normal** state: any listener on `SSH_PORT` is acceptable
   - In **failsafe** state: a `0.0.0.0` binding on `SSH_PORT` is required

If either check fails, the watchdog restarts sshd and polls every second for up to 5 seconds to confirm recovery. If SSH is still unhealthy after the restart it logs an error and retries on the next cycle.

---

## File locations

| Path | Description |
|---|---|
| `/usr/local/bin/netbird-watchdog.sh` | Main watchdog script |
| `/etc/systemd/system/netbird-watchdog.service` | Systemd unit |
| `/etc/ssh/sshd_config.d/99-netbird-watchdog.conf` | sshd drop-in (only present during failsafe) |
| `/run/netbird-watchdog/state` | Current state (`normal` or `failsafe`) |
| `/run/netbird-watchdog/failsafe_ip` | Resolved IP the firewall rule was added for |
| `/run/netbird-watchdog/firewall_backend` | Backend used at activation (`ufw` or `iptables`) |

The `/run/netbird-watchdog/` directory is ephemeral — it lives in `tmpfs` and is recreated by systemd on each boot via `RuntimeDirectory=`.

---

## Uninstallation

```bash
sudo systemctl stop netbird-watchdog
sudo systemctl disable netbird-watchdog
sudo rm /etc/systemd/system/netbird-watchdog.service
sudo rm /usr/local/bin/netbird-watchdog.sh
sudo rm -f /etc/ssh/sshd_config.d/99-netbird-watchdog.conf
sudo systemctl daemon-reload
sudo systemctl reload ssh   # or sshd
```

If the watchdog was in failsafe state when you uninstalled it, also clean up the firewall rule manually:

```bash
# ufw
sudo ufw status numbered
sudo ufw delete <rule_number>

# iptables
sudo iptables -L INPUT -n --line-numbers
sudo iptables -D INPUT <line_number>
```

---

## Notes

- The watchdog is **not lifecycle-bound** to `netbird.service`. It runs independently and will activate the failsafe even if Netbird fails to start on boot or never comes online at all.
- The sshd drop-in approach (`sshd_config.d/`) requires **OpenSSH 7.3+** and is safer than editing `sshd_config` directly — the main config file is never modified.
- The **firewall backend used at activation is saved** to state. If you change `FIREWALL=` in the unit while a failsafe is active, the watchdog will still use the originally saved backend to remove the rule on recovery.
- The firewall rule is scoped to a single resolved IP. If your failsafe domain's IP changes after activation, the original IP rule remains in place until Netbird recovers and the watchdog cleans it up. At that point the next failsafe activation will re-resolve the domain and add a fresh rule.
- Logs are written to both `stdout` (captured by journald) and the system logger (`logger`). View them with `journalctl -u netbird-watchdog`.
