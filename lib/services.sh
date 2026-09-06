#!/usr/bin/env bash
# services.sh - audit enabled services and listening sockets against the
# allowlist, and prompt to disable/block anything not on it.
# Intended to be sourced, not executed directly.

if [[ -n "${LOCKDOWN_SERVICES_SH_LOADED:-}" ]]; then
    return 0
fi
LOCKDOWN_SERVICES_SH_LOADED=1

ALLOWLIST_SERVICES=()
ALLOWLIST_PORTS=()   # entries like "22/tcp"

# load_allowlist <path>
# Parses a config file with lines like:
#   service:sshd
#   port:22/tcp
# Blank lines and lines starting with # are ignored.
load_allowlist() {
    local path="$1"

    if [[ ! -r "$path" ]]; then
        error "Allowlist file not readable: $path"
        exit 1
    fi

    ALLOWLIST_SERVICES=()
    ALLOWLIST_PORTS=()

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                  # strip comments
        line="$(echo -n "$line" | xargs)"   # trim whitespace
        [[ -z "$line" ]] && continue

        key="${line%%:*}"
        value="${line#*:}"
        case "$key" in
            service) ALLOWLIST_SERVICES+=("$value") ;;
            port)    ALLOWLIST_PORTS+=("$value") ;;
            *)       warn "Ignoring unrecognized allowlist line: $line" ;;
        esac
    done <"$path"

    info "Loaded allowlist: ${#ALLOWLIST_SERVICES[@]} service(s), ${#ALLOWLIST_PORTS[@]} port(s)."
    log_line "ALLOWLIST loaded from ${path}: services=[${ALLOWLIST_SERVICES[*]}] ports=[${ALLOWLIST_PORTS[*]}]"
}

# _in_array <needle> <array_name>
_in_array() {
    local needle="$1" arr_name="$2"
    local -n arr="$arr_name"
    local item
    for item in "${arr[@]}"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Listening port audit
# ---------------------------------------------------------------------------
# audit_listening_ports
# Parses `ss -tulpn` and flags any listener whose port/proto is not
# allow-listed. Offers to stop the owning systemd service (if identifiable).
audit_listening_ports() {
    if ! command -v ss >/dev/null 2>&1; then
        warn "'ss' not found; skipping listening-port audit."
        return
    fi

    info "Auditing listening TCP/UDP ports..."

    local ss_output
    ss_output="$(ss -tulpn 2>/dev/null)"

    local line proto local_addr port pid_prog service_hint
    while IFS= read -r line; do
        [[ "$line" =~ ^(Netid|State) ]] && continue
        [[ -z "$line" ]] && continue

        proto="$(awk '{print $1}' <<<"$line")"
        case "$proto" in
            tcp*) proto="tcp" ;;
            udp*) proto="udp" ;;
            *) continue ;;
        esac

        local_addr="$(awk '{print $5}' <<<"$line")"
        port="${local_addr##*:}"
        [[ "$port" =~ ^[0-9]+$ ]] || continue

        pid_prog="$(grep -o 'users:(("[^"]*"' <<<"$line" | head -n1 | sed -E 's/users:\(\("([^"]*)"/\1/')"
        [[ -z "$pid_prog" ]] && pid_prog="unknown"

        if _in_array "${port}/${proto}" ALLOWLIST_PORTS; then
            continue
        fi

        warn "Non-allowlisted listener: ${proto}/${port} (process: ${pid_prog})"
        service_hint="$(_guess_service_for_process "$pid_prog")"

        if [[ -n "$service_hint" ]]; then
            run_cmd "Stop and disable service '${service_hint}' (owns ${proto}/${port}, not in allowlist)" \
                -- systemctl disable --now "$service_hint"
        else
            info "Could not map process '${pid_prog}' to a systemd service; it will still be" \
                 "blocked at the firewall level (traffic to ${proto}/${port} denied by default policy)."
            log_line "UNMAPPED LISTENER ${proto}/${port} process=${pid_prog} (firewall default-deny will cover this)"
        fi
    done <<<"$ss_output"
}

# _guess_service_for_process <process_name>
# Best-effort: if a systemd unit with a matching name exists, return it.
_guess_service_for_process() {
    local proc="$1"
    [[ "$INIT_SYSTEM" == "systemd" ]] || return 0
    [[ "$proc" == "unknown" ]] && return 0

    if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${proc}.service"; then
        echo "${proc}.service"
    fi
}

# ---------------------------------------------------------------------------
# Enabled service audit
# ---------------------------------------------------------------------------
# audit_enabled_services
# Lists enabled services and prompts to disable anything not allow-listed.
audit_enabled_services() {
    if [[ "$INIT_SYSTEM" != "systemd" ]]; then
        warn "Automatic enabled-service audit is only implemented for systemd." \
             "Init system detected: ${INIT_SYSTEM}. Please review services manually."
        return
    fi

    info "Auditing enabled systemd services..."

    local unit svc_name
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        svc_name="${unit%.service}"

        if _in_array "$svc_name" ALLOWLIST_SERVICES; then
            continue
        fi

        warn "Enabled service not in allowlist: ${svc_name}"
        run_cmd "Disable service '${svc_name}' (stop now and prevent on boot)" \
            -- systemctl disable --now "$unit"
    done < <(systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null | awk '{print $1}')
}
