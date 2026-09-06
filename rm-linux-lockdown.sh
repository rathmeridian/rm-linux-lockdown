#!/usr/bin/env bash
# rm-linux-lockdown.sh - lock down a fresh Linux install.
#
# Closes non-essential open TCP/UDP ports, disables non-essential services,
# and configures the host firewall to default-deny inbound traffic except
# for an explicit allowlist. Every mutating command is confirmed with the
# user (unless --yes) and logged with its output.
#
# Usage: sudo ./rm-linux-lockdown.sh [options]
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
LIB_DIR="${SCRIPT_DIR}/lib"
DEFAULT_ALLOWLIST="${SCRIPT_DIR}/config/allowlist.conf"

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/detect.sh
source "${LIB_DIR}/detect.sh"
# shellcheck source=lib/firewall.sh
source "${LIB_DIR}/firewall.sh"
# shellcheck source=lib/services.sh
source "${LIB_DIR}/services.sh"

ASSUME_YES=0
DRY_RUN=0
ALLOWLIST_PATH="$DEFAULT_ALLOWLIST"
LOG_DIR=""

usage() {
    cat <<EOF
rm-linux-lockdown - harden a fresh Linux install

Usage: sudo $0 [options]

Options:
  -y, --yes             Non-interactive mode: auto-approve every action.
      --dry-run          Show what would be done without making any changes.
      --allowlist PATH   Path to an allowlist config file (default: ${DEFAULT_ALLOWLIST}).
      --log-dir PATH     Directory to write the session log into
                         (default: /var/log/lockdown, falling back to ./lockdown-logs).
  -h, --help             Show this help message and exit.

What it does:
  1. Detects your distro, init system, and available firewall backend.
  2. Audits enabled services and listening TCP/UDP ports against the
     allowlist, prompting to disable/stop anything not allow-listed.
  3. Configures the firewall with a default-deny-inbound policy that only
     permits the allow-listed ports.
  4. Logs every command it runs (and its output) to a session log file.

Customize config/allowlist.conf (or pass --allowlist) BEFORE running this
on a machine you access remotely, so you don't lock yourself out.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --allowlist)
            [[ $# -ge 2 ]] || { error "--allowlist requires a path argument"; exit 2; }
            ALLOWLIST_PATH="$2"
            shift 2
            ;;
        --log-dir)
            [[ $# -ge 2 ]] || { error "--log-dir requires a path argument"; exit 2; }
            LOG_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 2
            ;;
    esac
done

main() {
    require_root
    init_log "$LOG_DIR"

    echo "${C_BOLD}rm-linux-lockdown${C_RESET}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Running in DRY-RUN mode: no changes will be made."
    fi
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        warn "Running in non-interactive mode (--yes): all actions will be auto-approved."
    fi

    run_detection
    load_allowlist "$ALLOWLIST_PATH"

    echo
    info "Step 1/3: Auditing enabled services..."
    audit_enabled_services

    echo
    info "Step 2/3: Auditing listening TCP/UDP ports..."
    audit_listening_ports

    echo
    info "Step 3/3: Configuring firewall (default-deny inbound, allow-listed ports only)..."
    if confirm "Apply firewall lockdown using backend '${FIREWALL_BACKEND}'"; then
        fw_configure ALLOWLIST_PORTS
    else
        warn "Skipped firewall configuration."
        CHANGES_SKIPPED=$((CHANGES_SKIPPED + 1))
    fi

    print_summary

    if [[ "$CHANGES_FAILED" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
