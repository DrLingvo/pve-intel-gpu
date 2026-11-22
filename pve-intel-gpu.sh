#!/usr/bin/env bash
# pve-intel-gpu.sh
# Unified tool for Intel iGPU on Proxmox:
# - vGPU / SR-IOV enablement
# - Full passthrough with generation-aware ROM
# Auto-detects versions and CPU generation.
# Safe fallback. Logging: none / normal / debug.
# Log file follows script name.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME%.sh}.log"
LOG_LEVEL="${LOG_LEVEL:-normal}"

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    case "$LOG_LEVEL" in
        none) return 0 ;;
        normal) [[ "$level" == "DEBUG" ]] && return 0 ;;
        debug) ;;
        *) LOG_LEVEL=normal ;;
    esac
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
}
log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }
log_debug() { log DEBUG "$@"; }

STATE_DIR="${SCRIPT_DIR}/.pve-intel-gpu-state"
mkdir -p "$STATE_DIR"

backup_file() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    cp -a "$src" "${STATE_DIR}/$(basename "$src").bak"
    log_debug "Backed up $src"
}

restore_file() {
    local src="$1"
    local bak="${STATE_DIR}/$(basename "$src").bak"
    [[ -f "$bak" ]] || return 0
    cp -a "$bak" "$src"
    log_info "Restored $src"
}

rollback() {
    log_error "Error — attempting rollback"
    # extend with real restore steps
    log_warn "Rollback finished (best-effort). See $LOG_FILE"
}
trap rollback ERR

detect_versions() {
    log_info "Detecting versions..."
    PVE_VERSION="$(pveversion -v 2>/dev/null | awk '/proxmox-ve/ {print $2}' || echo unknown)"
    QEMU_VERSION="$(qemu-system-x86_64 --version 2>/dev/null | head -n1 | awk '{print $4}' || echo unknown)"
    KERNEL="$(uname -r)"
    log_info "PVE=$PVE_VERSION QEMU=$QEMU_VERSION Kernel=$KERNEL"
}

detect_cpu() {
    log_info "Detecting CPU / iGPU generation..."
    CPU_VENDOR="$(lscpu | awk '/Vendor ID:/ {print $3}')"
    CPU_MODEL="$(lscpu | awk -F: '/Model name:/ {gsub(/^ +/,"",$2); print $2}')"
    # TODO: refine generation detection (6-14 vs Ultra) via CPUID / PCI ID
    case "$CPU_VENDOR" in
        GenuineIntel) CPU_GEN="Intel" ;;
        *) CPU_GEN="non-Intel" ;;
    esac
    log_info "CPU: $CPU_MODEL ($CPU_GEN)"
}

# Placeholders — to be filled with real logic from AICodo repos + vGPU steps
mode_prepare()   { log_info "prepare: IOMMU, modules, blacklist (TODO)"; }
mode_vgpu()      { log_info "vGPU / SR-IOV enable (TODO)"; }
mode_passthrough(){ log_info "passthrough + ROM selection (TODO)"; }

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [--mode prepare|vgpu|passthrough|status|revert] [--vmid N]

LOG_LEVEL=debug $SCRIPT_NAME ...
EOF
}

main() {
    log_info "=== $SCRIPT_NAME started (level=$LOG_LEVEL) ==="
    detect_versions
    detect_cpu

    # simple arg parsing skeleton
    local mode="status"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode) mode="$2"; shift 2 ;;
            --vmid) VMID="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) log_warn "Unknown arg: $1"; shift ;;
        esac
    done

    case "$mode" in
        prepare)     mode_prepare ;;
        vgpu)        mode_vgpu ;;
        passthrough) mode_passthrough ;;
        status)      log_info "status (TODO)" ;;
        revert)      rollback ;;
        *) usage; exit 1 ;;
    esac

    log_info "=== Done ==="
}

main "$@"
