# rm-linux-lockdown

A bash utility to lock down a fresh Linux installation: it closes
non-essential open TCP/UDP ports, disables non-essential services, and
configures the host firewall with a default-deny-inbound policy. It works
across common distros/init systems by auto-detecting the package manager,
init system, and available firewall backend (`ufw`, `firewalld`, `nft`, or
`iptables`).

**Every action is confirmed with you before it runs** (unless you pass
`--yes`), and **every command and its output is logged** to a session log
file so you have a full audit trail.

## Quick start

```bash
# Review and edit the allowlist FIRST, especially if you access this
# machine remotely (e.g. over SSH).
$EDITOR config/allowlist.conf

# See what it would do, without changing anything:
sudo ./rm-linux-lockdown.sh --dry-run

# Run interactively (prompts before every change):
sudo ./rm-linux-lockdown.sh

# Run non-interactively (auto-approve everything, e.g. for provisioning):
sudo ./rm-linux-lockdown.sh --yes
```

## Safety first

- **Read `config/allowlist.conf` before running this on any box you access
  remotely.** Port `22/tcp` (SSH) is allow-listed by default so a default
  run won't lock you out over SSH, but if you rely on other ports/services
  (VPN, a web app, a database), add them to the allowlist first.
- Always try `--dry-run` first on a new machine to see exactly what would
  change.
- The script prompts before every mutating command by default. Answer `n`
  to skip an individual action, or `q` to abort the whole run immediately.
- Nothing is destructive at the filesystem level — it stops/disables
  services and adds firewall rules. Services can be re-enabled
  (`systemctl enable --now <service>`) and firewall rules can be reset
  (e.g. `ufw reset`, `firewall-cmd --reload` after edits, or
  `iptables -F && iptables -P INPUT ACCEPT`) if something goes wrong.

## What it does

1. **Detects the environment**: distro family, package manager, init
   system (systemd vs. sysvinit/openrc), and firewall backend.
2. **Audits enabled services** (systemd only) and prompts to disable any
   service not in the allowlist.
3. **Audits listening TCP/UDP ports** (via `ss -tulpn`) and, where the
   owning process maps to a systemd service, prompts to stop/disable it.
   Ports that can't be mapped to a service are still covered by the
   firewall's default-deny policy.
4. **Configures the firewall** with a default-deny-inbound / allow-outbound
   policy, explicitly opening only the ports listed in the allowlist.
5. **Logs everything**: each prompt decision, each command run, its exit
   code, and its captured output, to a timestamped log file (default
   `/var/log/lockdown/`, falling back to `./lockdown-logs/` if that isn't
   writable).

## Customizing the allowlist

Edit `config/allowlist.conf` (or copy it and pass `--allowlist <path>`).
Two entry types:

```
service:<systemd unit name, without .service>
port:<port number>/<tcp|udp>
```

Lines starting with `#` are comments.

## CLI options

```
-y, --yes             Non-interactive mode: auto-approve every action.
    --dry-run          Show what would be done without making any changes.
    --allowlist PATH   Path to an allowlist config file.
    --log-dir PATH     Directory to write the session log into.
-h, --help             Show help.
```

## Limitations

- Enabled-service auditing is implemented for `systemd` only; on
  sysvinit/OpenRC systems you'll get a warning to review services manually.
- Firewall persistence across reboots depends on what's available on the
  distro (e.g. `netfilter-persistent` for iptables, or writing
  `/etc/nftables.conf` for nftables); the script does its best and warns
  when it can't find a persistence mechanism.
- This tool complements, but doesn't replace, other hardening practices
  (patching, SSH key-based auth, fail2ban, SELinux/AppArmor, etc.).
