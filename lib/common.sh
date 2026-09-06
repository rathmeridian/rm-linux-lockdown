#!/usr/bin/env bash
# common.sh - logging, prompting, and safe command execution helpers for
# rm-linux-lockdown.sh
# Intended to be sourced, not executed directly.

# Guard against double-sourcing.
if [[ -n "${LOCKDOWN_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
LOCKDOWN_COMMON_SH_LOADED=1

# Globals expected to be set by the caller (rm-linux-lockdown.sh) before sourcing/using
# this file. Sensible defaults are provided here so lib files can be tested
# standalone.
: "${ASSUME_YES:=0}"
: "${DRY_RUN:=0}"
: "${LOG_FILE:=}"
: "${CHANGES_MADE:=0}"
: "${CHANGES_SKIPPED:=0}"
: "${CHANGES_FAILED:=0}"

# ---------------------------------------------------------------------------
# Color / output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

info()  { printf '%s[INFO]%s  %s\n'  "${C_BLUE}"   "${C_RESET}" "$*"; }
warn()  { printf '%s[WARN]%s  %s\n'  "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
error() { printf '%s[ERROR]%s %s\n'  "${C_RED}"    "${C_RESET}" "$*" >&2; }
ok()    { printf '%s[ OK ]%s  %s\n'  "${C_GREEN}"  "${C_RESET}" "$*"; }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# init_log <path>
# Creates the log file (and parent directory) and records a session header.
init_log() {
    local requested_dir="$1"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"

    local candidate_dirs=()
    if [[ -n "$requested_dir" ]]; then
        candidate_dirs+=("$requested_dir")
    else
        candidate_dirs+=("/var/log/lockdown")
    fi
    # Always have a fallback in the current directory.
    candidate_dirs+=("./lockdown-logs")

    local dir
    for dir in "${candidate_dirs[@]}"; do
        if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
            LOG_FILE="${dir%/}/lockdown-${ts}.log"
            break
        fi
    done

    if [[ -z "$LOG_FILE" ]]; then
        error "Unable to create a writable log directory (tried: ${candidate_dirs[*]})"
        exit 1
    fi

    {
        echo "==============================================================="
        echo "rm-linux-lockdown session started: $(date -Is)"
        echo "User: $(id -un) (uid=$(id -u))"
        echo "Host: $(hostname 2>/dev/null || echo unknown)"
        echo "Mode: dry_run=${DRY_RUN} assume_yes=${ASSUME_YES}"
        echo "==============================================================="
    } >>"$LOG_FILE"

    info "Logging to: $LOG_FILE"
}

# log_line <text>
# Appends a raw timestamped line to the log file.
log_line() {
    [[ -n "$LOG_FILE" ]] || return 0
    printf '[%s] %s\n' "$(date -Is)" "$*" >>"$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------
# confirm <description>
# Returns 0 (approved) or 1 (declined). Honors ASSUME_YES. A response of "q"
# aborts the entire script immediately.
confirm() {
    local description="$1"

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        log_line "AUTO-APPROVED (--yes): ${description}"
        return 0
    fi

    local reply
    while true; do
        printf '%s?%s %s %s[y/N/q]%s ' "${C_BOLD}" "${C_RESET}" "$description" "${C_YELLOW}" "${C_RESET}"
        read -r reply </dev/tty || reply="n"
        case "${reply,,}" in
            y|yes)
                log_line "APPROVED by user: ${description}"
                return 0
                ;;
            q|quit)
                log_line "USER QUIT at prompt: ${description}"
                warn "Aborting at user's request."
                exit 130
                ;;
            *)
                log_line "DECLINED by user: ${description}"
                return 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Safe command execution
# ---------------------------------------------------------------------------
# run_cmd <description> -- <command> [args...]
# Prompts (unless ASSUME_YES), respects DRY_RUN, executes, and logs the
# command plus captured output and exit code.
run_cmd() {
    local description="$1"
    shift
    if [[ "${1:-}" == "--" ]]; then
        shift
    fi

    if [[ $# -eq 0 ]]; then
        error "run_cmd called with no command for: ${description}"
        return 2
    fi

    local cmd_display
    cmd_display="$(printf '%q ' "$@")"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] ${description}"
        info "          would run: ${cmd_display}"
        log_line "DRY-RUN: ${description} :: ${cmd_display}"
        return 0
    fi

    if ! confirm "${description} (command: ${cmd_display})"; then
        CHANGES_SKIPPED=$((CHANGES_SKIPPED + 1))
        warn "Skipped: ${description}"
        return 1
    fi

    log_line "RUN: ${cmd_display}"
    local output
    local status
    output="$("$@" 2>&1)"
    status=$?

    {
        echo "  exit_code: ${status}"
        echo "  output:"
        if [[ -n "$output" ]]; then
            sed 's/^/    /' <<<"$output"
        else
            echo "    (no output)"
        fi
    } >>"$LOG_FILE"

    if [[ $status -eq 0 ]]; then
        ok "${description}"
        CHANGES_MADE=$((CHANGES_MADE + 1))
    else
        error "${description} (exit code ${status})"
        [[ -n "$output" ]] && printf '%s\n' "$output" >&2
        CHANGES_FAILED=$((CHANGES_FAILED + 1))
    fi

    return $status
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "This script must be run as root (try: sudo $0 \"\$@\")."
        exit 1
    fi
}

print_summary() {
    echo
    echo "${C_BOLD}=== rm-linux-lockdown Summary ===${C_RESET}"
    echo "  Changes applied : ${CHANGES_MADE}"
    echo "  Changes skipped : ${CHANGES_SKIPPED}"
    echo "  Changes failed  : ${CHANGES_FAILED}"
    [[ -n "$LOG_FILE" ]] && echo "  Full log        : ${LOG_FILE}"
    log_line "SUMMARY: applied=${CHANGES_MADE} skipped=${CHANGES_SKIPPED} failed=${CHANGES_FAILED}"
}
