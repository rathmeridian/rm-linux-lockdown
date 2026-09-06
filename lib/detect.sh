#!/usr/bin/env bash
# detect.sh - environment detection: distro, package manager, init system,
# and firewall backend. Intended to be sourced, not executed directly.

if [[ -n "${LOCKDOWN_DETECT_SH_LOADED:-}" ]]; then
    return 0
fi
LOCKDOWN_DETECT_SH_LOADED=1

DISTRO_ID=""
DISTRO_FAMILY=""      # debian | rhel | arch | suse | unknown
PKG_MANAGER=""         # apt | dnf | yum | pacman | zypper | unknown
INIT_SYSTEM=""         # systemd | sysvinit | openrc | unknown
FIREWALL_BACKEND=""    # ufw | firewalld | nft | iptables | none

# detect_distro
# Populates DISTRO_ID, DISTRO_FAMILY, PKG_MANAGER.
detect_distro() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        local like="${ID_LIKE:-}"
        case "${DISTRO_ID} ${like}" in
            *debian*|*ubuntu*) DISTRO_FAMILY="debian" ;;
            *rhel*|*fedora*|*centos*) DISTRO_FAMILY="rhel" ;;
            *arch*) DISTRO_FAMILY="arch" ;;
            *suse*) DISTRO_FAMILY="suse" ;;
            *) DISTRO_FAMILY="unknown" ;;
        esac
    else
        DISTRO_ID="unknown"
        DISTRO_FAMILY="unknown"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
    else
        PKG_MANAGER="unknown"
    fi
}

# detect_init_system
# Populates INIT_SYSTEM by inspecting PID 1.
detect_init_system() {
    local pid1_comm
    pid1_comm="$(ps -p 1 -o comm= 2>/dev/null || true)"

    if [[ "$pid1_comm" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1 && [[ -d /etc/runlevels ]]; then
        INIT_SYSTEM="openrc"
    elif [[ -x /etc/init.d/rc || -d /etc/init.d ]]; then
        INIT_SYSTEM="sysvinit"
    else
        INIT_SYSTEM="unknown"
    fi
}

# detect_firewall_backend
# Priority: ufw (active) > firewalld (active) > ufw (installed) >
# firewalld (installed) > nft > iptables > none.
detect_firewall_backend() {
    if command -v ufw >/dev/null 2>&1; then
        FIREWALL_BACKEND="ufw"
        return
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        FIREWALL_BACKEND="firewalld"
        return
    fi
    if command -v nft >/dev/null 2>&1; then
        FIREWALL_BACKEND="nft"
        return
    fi
    if command -v iptables >/dev/null 2>&1; then
        FIREWALL_BACKEND="iptables"
        return
    fi
    FIREWALL_BACKEND="none"
}

# run_detection
# Convenience wrapper to run all detection routines and print a summary.
run_detection() {
    detect_distro
    detect_init_system
    detect_firewall_backend

    info "Detected distro:    ${DISTRO_ID} (family: ${DISTRO_FAMILY})"
    info "Package manager:    ${PKG_MANAGER}"
    info "Init system:        ${INIT_SYSTEM}"
    info "Firewall backend:   ${FIREWALL_BACKEND}"

    log_line "DETECT distro=${DISTRO_ID} family=${DISTRO_FAMILY} pkg_mgr=${PKG_MANAGER} init=${INIT_SYSTEM} firewall=${FIREWALL_BACKEND}"

    if [[ "$FIREWALL_BACKEND" == "none" ]]; then
        warn "No firewall tool detected (ufw/firewalld/nft/iptables all missing)."
    fi
}
