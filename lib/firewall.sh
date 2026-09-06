#!/usr/bin/env bash
# firewall.sh - backend-specific firewall configuration.
# Provides a single entrypoint, fw_configure, which applies a default-deny
# inbound / allow-outbound policy and opens only the allow-listed ports,
# using whichever backend was detected in detect.sh. All mutating commands
# go through run_cmd (see common.sh) so they are confirmed, logged, and
# skippable.
#
# Intended to be sourced, not executed directly.

if [[ -n "${LOCKDOWN_FIREWALL_SH_LOADED:-}" ]]; then
    return 0
fi
LOCKDOWN_FIREWALL_SH_LOADED=1

# fw_configure <allowed_ports_array_name>
# allowed_ports_array_name must name a bash array of "port/proto" entries,
# e.g. ("22/tcp" "80/tcp" "53/udp").
fw_configure() {
    local -n _allowed_ports="$1"

    case "$FIREWALL_BACKEND" in
        ufw)       fw_configure_ufw _allowed_ports ;;
        firewalld) fw_configure_firewalld _allowed_ports ;;
        nft)       fw_configure_nft _allowed_ports ;;
        iptables)  fw_configure_iptables _allowed_ports ;;
        *)
            warn "No supported firewall backend available; skipping firewall configuration."
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# ufw
# ---------------------------------------------------------------------------
fw_configure_ufw() {
    local -n ports="$1"

    run_cmd "Set ufw default policy: deny incoming" -- ufw default deny incoming
    run_cmd "Set ufw default policy: allow outgoing" -- ufw default allow outgoing

    local entry port proto
    for entry in "${ports[@]}"; do
        port="${entry%%/*}"
        proto="${entry##*/}"
        run_cmd "Allow ${entry} through ufw" -- ufw allow "${port}/${proto}"
    done

    run_cmd "Enable ufw" -- ufw --force enable
}

# ---------------------------------------------------------------------------
# firewalld
# ---------------------------------------------------------------------------
fw_configure_firewalld() {
    local -n ports="$1"

    run_cmd "Set firewalld default zone target to DROP (default zone)" \
        -- firewall-cmd --permanent --zone=public --set-target=DROP

    local entry
    for entry in "${ports[@]}"; do
        run_cmd "Allow ${entry} through firewalld" \
            -- firewall-cmd --permanent --zone=public --add-port="${entry}"
    done

    run_cmd "Reload firewalld to apply permanent rules" -- firewall-cmd --reload
}

# ---------------------------------------------------------------------------
# nftables
# ---------------------------------------------------------------------------
fw_configure_nft() {
    local -n ports="$1"

    run_cmd "Create nft table inet lockdown (if missing)" \
        -- nft add table inet lockdown
    run_cmd "Create nft input chain with default drop policy" \
        -- nft add chain inet lockdown input '{ type filter hook input priority 0; policy drop; }'
    run_cmd "Allow loopback traffic" \
        -- nft add rule inet lockdown input iif lo accept
    run_cmd "Allow established/related connections" \
        -- nft add rule inet lockdown input ct state established,related accept

    local entry port proto
    for entry in "${ports[@]}"; do
        port="${entry%%/*}"
        proto="${entry##*/}"
        run_cmd "Allow ${entry} via nft" \
            -- nft add rule inet lockdown input "${proto}" dport "${port}" accept
    done

    if command -v nft >/dev/null 2>&1 && [[ -d /etc/nftables.d ]]; then
        run_cmd "Persist nft ruleset to /etc/nftables.conf" \
            -- bash -c 'nft list ruleset > /etc/nftables.conf'
    else
        warn "Persisting nft rules across reboot varies by distro; consider adding" \
             "'nft list ruleset > /etc/nftables.conf' to your nftables service config."
    fi
}

# ---------------------------------------------------------------------------
# iptables (legacy fallback)
# ---------------------------------------------------------------------------
fw_configure_iptables() {
    local -n ports="$1"

    run_cmd "Allow loopback traffic (iptables)" -- iptables -A INPUT -i lo -j ACCEPT
    run_cmd "Allow established/related connections (iptables)" \
        -- iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    local entry port proto
    for entry in "${ports[@]}"; do
        port="${entry%%/*}"
        proto="${entry##*/}"
        run_cmd "Allow ${entry} via iptables" \
            -- iptables -A INPUT -p "${proto}" --dport "${port}" -j ACCEPT
    done

    run_cmd "Set default INPUT policy to DROP" -- iptables -P INPUT DROP

    if command -v ip6tables >/dev/null 2>&1; then
        run_cmd "Allow loopback traffic (ip6tables)" -- ip6tables -A INPUT -i lo -j ACCEPT
        run_cmd "Allow established/related connections (ip6tables)" \
            -- ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        for entry in "${ports[@]}"; do
            port="${entry%%/*}"
            proto="${entry##*/}"
            run_cmd "Allow ${entry} via ip6tables" \
                -- ip6tables -A INPUT -p "${proto}" --dport "${port}" -j ACCEPT
        done
        run_cmd "Set default INPUT policy to DROP (ip6tables)" -- ip6tables -P INPUT DROP
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        run_cmd "Persist iptables rules via netfilter-persistent" -- netfilter-persistent save
    elif command -v service >/dev/null 2>&1 && [[ -e /etc/init.d/iptables ]]; then
        run_cmd "Persist iptables rules" -- service iptables save
    else
        warn "No persistence helper found for iptables; rules will not survive a reboot" \
             "unless you save them manually (e.g. iptables-save > /etc/iptables/rules.v4)."
    fi
}
