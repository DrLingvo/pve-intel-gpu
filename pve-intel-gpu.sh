#!/usr/bin/env bash
# pve-intel-gpu.sh
# Unified tool for Intel iGPU on Proxmox VE:
#   - vGPU, technology chosen by the iGPU generation:
#       Gen8-9 (Broadwell .. Comet Lake): GVT-g mediated devices (mdev)
#       Gen12+ (Tiger Lake .. Core Ultra): SR-IOV virtual functions
#   - guest profiles (--guest android for BlissOS, linux, windows)
#   - full passthrough with generation-aware ROM (6-14 gen / Core Ultra 1-2)
# Detects PVE / QEMU / kernel and the iGPU generation by PCI device ID.
#
# Ownership contract (so other host tools are not broken):
#   - host: only our own files (modprobe.d, modules-load.d, systemd unit) and the
#     kernel parameters we added (they are recorded and removed one by one);
#   - VM:   only the hostpciN entries we created, "vga" (old value is saved), and our
#     "-set device.hostpciN.{addr,bus,x-igd-*}" tokens inside "args:". The rest of
#     the args line (for example the realpc-clean-build ACPI/SMBIOS profile) is kept;
#   - never touches kvm*.ko, pve-qemu-kvm, pve-edk2-firmware or APT holds;
#   - shares the lock /run/lock/pve-host-tools.lock and args.d fragments with other
#     host tools; the rules are in CONTRACT.md.
# Logging: none / normal / debug. The log file follows the script name.

set -Eeuo pipefail

VERSION="0.3.0"
SCRIPT_NAME="$(basename "$0")"
# resolve the symlink installed by install.sh (/usr/local/sbin/pve-intel-gpu)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# ROOT is empty on a real host; the test suite points it to a fake tree.
ROOT="${PIG_ROOT:-}"
STATE_DIR="$ROOT/var/lib/pve-intel-gpu"
LOCK_FILE="$ROOT/run/lock/pve-host-tools.lock"
KVM_ROM_DIR="$ROOT/usr/share/kvm"
SYS_PCI="$ROOT/sys/bus/pci/devices"
PROC_CMDLINE="$ROOT/proc/cmdline"
GRUB_DEFAULT="$ROOT/etc/default/grub"
KERNEL_CMDLINE="$ROOT/etc/kernel/cmdline"
MODULES_FILE="$ROOT/etc/modules-load.d/pve-intel-gpu.conf"
MODPROBE_FILE="$ROOT/etc/modprobe.d/pve-intel-gpu.conf"
VF_UNIT_NAME="pve-intel-gpu-vfs.service"
VF_UNIT="$ROOT/etc/systemd/system/$VF_UNIT_NAME"
REALPC_DIR="${REALPC_DIR:-/root/realpc}"
REALPC_STATE="$ROOT$REALPC_DIR/.realpc-state"
IGPU_BDF="${IGPU_BDF:-0000:00:02.0}"
# ROM catalog shipped with the tool in bios/ (PIG_ROMS_DIR overrides it for tests)
ROMS_DIR="${PIG_ROMS_DIR:-$SCRIPT_DIR/bios}"
ROM_CATALOG="$ROMS_DIR/catalog.tsv"
ROM_SUMS="$ROMS_DIR/SHA256SUMS"
# Shared host-tools contract (see CONTRACT.md): lock + args.d fragments
CONTRACT_VERSION=1
ARGS_D="$ROOT/etc/pve-host-tools/args.d"
ARGS_FRAGMENT_NAME="50-pve-intel-gpu.args"
AUDIO_BDF="0000:00:1f.3"

# ---------------------------------------------------------------- options
MODE="check"; VMID=""; VF=""; NUMVFS=""; ROM=""; GMS="0x2"; AUDIO=0
ROM_IDS=""; ROM_QEMU="10"; ROM_SOURCE=""
GUEST=""; DISPLAY_MODE=""; GVT_TYPE=""
DKMS_DEB=""; YES=0; DRY_RUN=0; FORCE=0
LOG_LEVEL="${LOG_LEVEL:-normal}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/${SCRIPT_NAME%.sh}.log}"

usage() {
    cat <<EOF
$SCRIPT_NAME $VERSION - Intel iGPU on Proxmox VE (SR-IOV vGPU and full passthrough)

Usage: $SCRIPT_NAME --mode MODE [options]

Modes:
  check | status   Read-only report: host, iGPU, IOMMU, VFs, VMs, realpc state
  prepare          Enable IOMMU (intel_iommu=on iommu=pt) and load vfio modules
  vgpu             vGPU by iGPU generation: GVT-g (Gen8-9) or SR-IOV (Gen12+)
                   Host: GVT-g (i915.enable_gvt, kvmgt) or SR-IOV VFs kept across reboots
                   With --vmid: give the VM a GVT-g mdev or a free VF
  passthrough      Host: bind the iGPU to vfio-pci
                   With --vmid: hostpci + ROM + IGD args + vga none for the VM
  reapply          With --vmid: put our IGD args/vga back (e.g. after realpc configvm)
  revert           With --vmid: remove only our changes from the VM
                   Without:    remove our host changes (VMs must be reverted first)
  rom-add          Add a ROM to bios/: --rom FILE --ids "46d1 46d0" [--qemu 10] [--source TEXT]
                   (copies the file, updates bios/SHA256SUMS and bios/catalog.tsv)

Options:
  --vmid N         VM ID
  --guest G        android (BlissOS) | linux | windows: display and driver defaults, hints
  --display D      vgpu: the VM screen is the vGPU itself (GVT-g display=on, noVNC)
                   console: keep the VM's own vga, vGPU only renders/decodes
                   default: vgpu for android/linux with GVT-g, console otherwise
  --gvt-type T     GVT-g type, e.g. i915-GVTg_V5_4 (default: first with a free slot,
                   order V5_4, V5_2, V5_8, V5_1)
  --vf N           VF number to assign (1..7); default: first free VF
  --vfs N          Number of VFs to create (default: 7, capped by sriov_totalvfs)
  --rom FILE|NAME  ROM file (unverified, your choice) or a catalog/kvm name;
                   default: bios/catalog.tsv by PCI ID, checked against bios/SHA256SUMS
  --gms HEX        x-igd-gms value (default 0x2 = 64 MiB)
  --audio          Also pass the onboard audio $AUDIO_BDF (passthrough)
  --dkms-deb FILE  Install this i915-sriov-dkms .deb if SR-IOV is not available
  --yes            Do not ask for confirmation
  --dry-run        Show what would change, change nothing
  --force          Skip the minimum QEMU check and the ROM checksum check
  --log LEVEL      none | normal | debug (also LOG_LEVEL=...)
  --logfile FILE   Log file (default: $LOG_FILE)
  -h, --help       This help;  --version  print version

Examples:
  LOG_LEVEL=debug $SCRIPT_NAME --mode status
  $SCRIPT_NAME --mode prepare
  $SCRIPT_NAME --mode vgpu --vmid 101 --guest android
  $SCRIPT_NAME --mode passthrough --vmid 100 --dry-run
EOF
}

val() { [[ -n "$2" && "$2" != --* ]] || { echo "missing value for $1" >&2; exit 2; }; printf '%s' "$2"; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)     MODE="$(val --mode "${2-}")"; shift 2 ;;
            --vmid)     VMID="$(val --vmid "${2-}")"; shift 2 ;;
            --vf)       VF="$(val --vf "${2-}")"; shift 2 ;;
            --vfs)      NUMVFS="$(val --vfs "${2-}")"; shift 2 ;;
            --rom)      ROM="$(val --rom "${2-}")"; shift 2 ;;
            --gms)      GMS="$(val --gms "${2-}")"; shift 2 ;;
            --audio)    AUDIO=1; shift ;;
            --dkms-deb) DKMS_DEB="$(val --dkms-deb "${2-}")"; shift 2 ;;
            --ids)      ROM_IDS="$(val --ids "${2-}")"; shift 2 ;;
            --guest)    GUEST="$(val --guest "${2-}")"; shift 2 ;;
            --display)  DISPLAY_MODE="$(val --display "${2-}")"; shift 2 ;;
            --gvt-type) GVT_TYPE="$(val --gvt-type "${2-}")"; shift 2 ;;
            --qemu)     ROM_QEMU="$(val --qemu "${2-}")"; shift 2 ;;
            --source)   ROM_SOURCE="$(val --source "${2-}")"; shift 2 ;;
            --yes|-y)   YES=1; shift ;;
            --dry-run)  DRY_RUN=1; shift ;;
            --force)    FORCE=1; shift ;;
            --log)      LOG_LEVEL="$(val --log "${2-}")"; shift 2 ;;
            --logfile)  LOG_FILE="$(val --logfile "${2-}")"; shift 2 ;;
            -h|--help)  usage; exit 0 ;;
            --version)  echo "$VERSION"; exit 0 ;;
            *) echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
        esac
    done
    [[ "$MODE" == status ]] && MODE=check
    case "$MODE" in check|prepare|vgpu|passthrough|reapply|revert|rom-add) ;;
        *) echo "Unknown mode: $MODE (see --help)" >&2; exit 2 ;; esac
    case "$LOG_LEVEL" in none|normal|debug) ;;
        *) echo "--log must be none, normal or debug" >&2; exit 2 ;; esac
    [[ -z "$VMID" || "$VMID" =~ ^[1-9][0-9]*$ ]] || { echo "--vmid must be a number" >&2; exit 2; }
    [[ -z "$VF" || "$VF" =~ ^[1-9][0-9]*$ ]] || { echo "--vf must be a positive number" >&2; exit 2; }
    [[ -z "$NUMVFS" || "$NUMVFS" =~ ^[1-9][0-9]*$ ]] || { echo "--vfs must be a positive number" >&2; exit 2; }
    [[ "$GMS" =~ ^0x[0-9a-fA-F]+$ ]] || { echo "--gms must be hex, e.g. 0x2" >&2; exit 2; }
    case "$GUEST" in ""|android|linux|windows) ;; *) echo "--guest must be android, linux or windows" >&2; exit 2 ;; esac
    case "$DISPLAY_MODE" in ""|vgpu|console) ;; *) echo "--display must be vgpu or console" >&2; exit 2 ;; esac
    [[ -z "$GVT_TYPE" || "$GVT_TYPE" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "--gvt-type: e.g. i915-GVTg_V5_4" >&2; exit 2; }
    if [[ "$MODE" == reapply && -z "$VMID" ]]; then echo "reapply needs --vmid" >&2; exit 2; fi
    if [[ "$MODE" == rom-add ]]; then
        [[ -n "$ROM" && -n "$ROM_IDS" ]] || { echo "rom-add needs --rom FILE and --ids \"46d1 46d0\"" >&2; exit 2; }
        [[ "$ROM_IDS" =~ ^[0-9a-fA-F\ ]+$ ]] || { echo "--ids: hex PCI device ID prefixes separated by spaces" >&2; exit 2; }
        [[ "$ROM_QEMU" =~ ^[0-9]+$ ]] || { echo "--qemu must be a number" >&2; exit 2; }
    fi
    return 0
}

# ---------------------------------------------------------------- logging
# Console: INFO/OK/WARN depend on the level, ERROR is always shown (stderr).
# File: written unless the level is none; DEBUG only at the debug level.
_log() {
    local level=$1; shift
    local msg="$*" ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ "$level" == ERROR ]] || { [[ "$LOG_LEVEL" != none ]] && { [[ "$level" != DEBUG ]] || [[ "$LOG_LEVEL" == debug ]]; }; }; then
        printf '[%s] %s\n' "$level" "$msg" >&2
    fi
    [[ "$LOG_LEVEL" == none || -z "$LOG_FILE" ]] && return 0
    [[ "$level" == DEBUG && "$LOG_LEVEL" != debug ]] && return 0
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >>"$LOG_FILE" 2>/dev/null || true
}
log_info()  { _log INFO "$@"; }
log_ok()    { _log OK "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { _log DEBUG "$@"; }
die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------- helpers
have() { command -v "$1" >/dev/null 2>&1; }
readf() { cat "$1" 2>/dev/null || true; }

run() {
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '[dry-run]' >&2; printf ' %q' "$@" >&2; printf '\n' >&2
        return 0
    fi
    log_debug "run: $*"
    "$@"
}

confirm() {
    [[ "$YES" == 1 || "$DRY_RUN" == 1 ]] && return 0
    [[ -t 0 ]] || die "Not interactive: add --yes to confirm ($1)"
    local a; read -r -p "$1 [y/N] " a
    [[ "$a" == y || "$a" == Y || "$a" == yes ]]
}

need_root() {
    [[ -n "$ROOT" || "$(id -u)" == 0 ]] || die "This mode needs root"
}

LOCK_FD=""
take_lock() {
    [[ "$DRY_RUN" == 1 ]] && return 0
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec {LOCK_FD}>"$LOCK_FILE"
    if have flock; then
        flock -w "${PIG_LOCK_TIMEOUT:-60}" "$LOCK_FD" || die "Another host tool holds $LOCK_FILE (realpc-setup? another run?)"
    fi
    log_debug "Lock taken: $LOCK_FILE"
}

# ---------------------------------------------------------------- state
STATE_FILE="$STATE_DIR/state"
st_get() { [[ -f "$STATE_FILE" ]] && sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1; return 0; }
st_set() {
    [[ "$DRY_RUN" == 1 ]] && return 0
    local cur; cur="$( { grep -v "^$1=" "$STATE_FILE" 2>/dev/null || true; } ; echo "$1=$2")"
    file_put "$STATE_FILE" <<<"$cur"
}
st_del() {
    [[ "$DRY_RUN" == 1 || ! -f "$STATE_FILE" ]] && return 0
    file_put "$STATE_FILE" < <(grep -v "^$1=" "$STATE_FILE" || true)
}

# ---------------------------------------------------------------- transaction
# Every file we change and every VM key we set is journaled. On error the
# journal is replayed backwards, so a failed run leaves the host as it was.
TXN_DIR=""; TXN_VM=(); NEED_BOOT_REFRESH=0; NEED_INITRAMFS=0; UNIT_TOUCHED=0
VF_RESTORE=""; FILE_CHANGED=0

txn_begin() {
    [[ "$DRY_RUN" == 1 ]] && return 0
    mkdir -p "$STATE_DIR"
    TXN_DIR="$(mktemp -d "$STATE_DIR/txn.XXXXXX")"
    : >"$TXN_DIR/journal"
    # die/exit and set -e failures both end in the EXIT trap
    trap 'txn_rollback' EXIT
    trap 'exit 130' INT TERM
}

txn_commit() {
    [[ "$DRY_RUN" == 1 ]] && return 0
    trap - EXIT INT TERM
    [[ -n "$TXN_DIR" ]] && rm -rf "$TXN_DIR"
    TXN_DIR=""
}

_jkey() { local p="${1#"$ROOT"}"; printf '%s' "${p//\//%}"; }

_journal_file() {
    local p=$1 k
    [[ -n "$TXN_DIR" ]] || return 0
    grep -qxF "$p" "$TXN_DIR/journal" && return 0
    k="$(_jkey "$p")"
    [[ -e "$p" ]] && cp -a "$p" "$TXN_DIR/$k"
    printf '%s\n' "$p" >>"$TXN_DIR/journal"
}

# file_put PATH < content   (sets FILE_CHANGED=1 when the content differs)
# Never call it on the right side of a pipe: that runs it in a subshell.
file_put() {
    local p=$1 tmp
    FILE_CHANGED=0
    tmp="$(mktemp)"
    cat >"$tmp"
    if [[ -f "$p" ]] && cmp -s "$tmp" "$p"; then rm -f "$tmp"; return 0; fi
    FILE_CHANGED=1
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '[dry-run] would write %s\n' "${p#"$ROOT"}" >&2
        if [[ -e "$p" ]]; then diff -u "$p" "$tmp" 2>/dev/null | tail -n +3 | sed 's/^/    /' >&2 || true
        else sed 's/^/    +/' "$tmp" >&2; fi
        rm -f "$tmp"; return 0
    fi
    _journal_file "$p"
    mkdir -p "$(dirname "$p")"
    cat "$tmp" >"$p.pig-tmp" && mv -f "$p.pig-tmp" "$p"
    rm -f "$tmp"
    log_debug "Wrote ${p#"$ROOT"}"
}

file_del() {
    local p=$1
    FILE_CHANGED=0
    [[ -e "$p" ]] || return 0
    FILE_CHANGED=1
    if [[ "$DRY_RUN" == 1 ]]; then printf '[dry-run] would remove %s\n' "${p#"$ROOT"}" >&2; return 0; fi
    _journal_file "$p"
    rm -f "$p"
    log_debug "Removed ${p#"$ROOT"}"
}

# vm_set VMID KEY VALUE   ("" deletes the key); the old value is journaled
vm_set() {
    local vmid=$1 key=$2 val=$3 old
    old="$(vm_get "$vmid" "$key")"
    [[ "$old" == "$val" ]] && return 0
    TXN_VM+=("$vmid"$'\t'"$key"$'\t'"${old:-__ABSENT__}")
    if [[ -z "$val" ]]; then
        [[ -z "$old" ]] && return 0
        run qm set "$vmid" --delete "$key" >/dev/null
    else
        run qm set "$vmid" "--$key" "$val" >/dev/null
    fi
    VM_CACHE_ID=""
    log_info "VM $vmid: $key = ${val:-<deleted>}"
}

txn_rollback() {
    local rc=$?
    # a failing command substitution must not roll back on its own
    [[ "$BASHPID" == "$$" ]] || exit "$rc"
    trap - EXIT INT TERM
    [[ -n "$TXN_DIR" && "$rc" != 0 ]] || exit "$rc"
    log_error "Failed (exit $rc) - rolling back this run"
    local i e vmid key old
    for (( i=${#TXN_VM[@]}-1; i>=0; i-- )); do
        e="${TXN_VM[$i]}"; vmid="${e%%$'\t'*}"; e="${e#*$'\t'}"; key="${e%%$'\t'*}"; old="${e#*$'\t'}"
        if [[ "$old" == __ABSENT__ ]]; then qm set "$vmid" --delete "$key" >/dev/null 2>&1 || log_error "VM $vmid: could not delete $key"
        else qm set "$vmid" "--$key" "$old" >/dev/null 2>&1 || log_error "VM $vmid: could not restore $key"; fi
    done
    if [[ -n "$VF_RESTORE" ]]; then
        echo 0 >"$SYS_PCI/$IGPU_BDF/sriov_numvfs" 2>/dev/null || true
        [[ "$VF_RESTORE" != 0 ]] && { echo "$VF_RESTORE" >"$SYS_PCI/$IGPU_BDF/sriov_numvfs" 2>/dev/null || true; }
    fi
    local p k
    if [[ -f "$TXN_DIR/journal" ]]; then
        while IFS= read -r p; do
            k="$(_jkey "$p")"
            if [[ -e "$TXN_DIR/$k" ]]; then cp -a "$TXN_DIR/$k" "$p"; else rm -f "$p"; fi
            log_info "Restored ${p#"$ROOT"}"
        done < <(tac "$TXN_DIR/journal")
    fi
    if [[ "$UNIT_TOUCHED" == 1 ]] && have systemctl; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        [[ -e "$VF_UNIT" ]] || systemctl disable "$VF_UNIT_NAME" >/dev/null 2>&1 || true
    fi
    [[ "$NEED_BOOT_REFRESH" == 1 ]] && { refresh_boot || log_error "Bootloader refresh failed - run it manually"; }
    [[ "$NEED_INITRAMFS" == 1 ]] && { run update-initramfs -u -k all >/dev/null 2>&1 || log_error "update-initramfs failed - run it manually"; }
    rm -rf "$TXN_DIR"
    log_warn "Rollback finished. Log: $LOG_FILE"
    exit "$rc"
}

# ---------------------------------------------------------------- detection
PVE_VERSION=unknown; QEMU_VERSION=unknown; QEMU_MAJOR=0; KERNEL=unknown
detect_versions() {
    PVE_VERSION="$( { pveversion 2>/dev/null || true; } | sed -n 's|^pve-manager/\([^/ ]*\).*|\1|p' | head -n1)"
    [[ -n "$PVE_VERSION" ]] || PVE_VERSION=unknown
    # dpkg is the source of truth: custom builds (realpc) keep the package name
    QEMU_VERSION="$(dpkg-query -W -f='${Version}' pve-qemu-kvm 2>/dev/null || true)"
    [[ -n "$QEMU_VERSION" ]] || QEMU_VERSION=unknown
    QEMU_MAJOR="${QEMU_VERSION%%.*}"; [[ "$QEMU_MAJOR" =~ ^[0-9]+$ ]] || QEMU_MAJOR=0
    KERNEL="$(uname -r)"
    log_debug "PVE=$PVE_VERSION QEMU=$QEMU_VERSION Kernel=$KERNEL"
}

# Fills IGPU_* from sysfs. Generation by PCI device ID (prefix table).
IGPU_PRESENT=0; IGPU_DID=""; IGPU_NAME="not found"; IGPU_GENS=""
IGPU_TECH=none; IGPU_DRIVER=none; IGPU_TOTALVFS=0; IGPU_NUMVFS=0
detect_igpu() {
    local dev="$SYS_PCI/$IGPU_BDF" vendor class
    vendor="$(readf "$dev/vendor")"; class="$(readf "$dev/class")"
    if [[ "$vendor" != 0x8086 || ! "$class" =~ ^0x03 ]]; then
        IGPU_PRESENT=0; return 0
    fi
    IGPU_PRESENT=1
    IGPU_DID="$(readf "$dev/device")"; IGPU_DID="${IGPU_DID#0x}"; IGPU_DID="${IGPU_DID,,}"
    if [[ -L "$dev/driver" ]]; then IGPU_DRIVER="$(basename "$(readlink "$dev/driver")")"; else IGPU_DRIVER=none; fi
    IGPU_TOTALVFS="$(readf "$dev/sriov_totalvfs")"; [[ "$IGPU_TOTALVFS" =~ ^[0-9]+$ ]] || IGPU_TOTALVFS=0
    IGPU_NUMVFS="$(readf "$dev/sriov_numvfs")"; [[ "$IGPU_NUMVFS" =~ ^[0-9]+$ ]] || IGPU_NUMVFS=0
    # name + generation numbers as they appear in CPU names (ROM choice: bios/catalog.tsv)
    case "$IGPU_DID" in
        0f3?)            IGPU_NAME="Bay Trail (Atom)"; IGPU_GENS="" ;;
        04??|0a??|0d??)  IGPU_NAME="Haswell (4th gen)"; IGPU_GENS="4" ;;
        16??|22b?)       IGPU_NAME="Broadwell/Braswell (5th gen)"; IGPU_GENS="5"; IGPU_TECH=gvt ;;
        19??)            IGPU_NAME="Skylake (6th gen)"; IGPU_GENS="6"; IGPU_TECH=gvt ;;
        5a8?)            IGPU_NAME="Apollo Lake (Atom/Celeron)"; IGPU_GENS=""; IGPU_TECH=gvt ;;
        59??|87c0)       IGPU_NAME="Kaby/Amber Lake (7th-8th gen)"; IGPU_GENS="7 8"; IGPU_TECH=gvt ;;
        318?)            IGPU_NAME="Gemini Lake (Celeron/Pentium)"; IGPU_GENS="" ;;
        3e??|87ca)       IGPU_NAME="Coffee Lake (8th-9th gen)"; IGPU_GENS="8 9"; IGPU_TECH=gvt ;;
        9b??)            IGPU_NAME="Comet Lake (10th gen)"; IGPU_GENS="10"; IGPU_TECH=gvt ;;
        8a??)            IGPU_NAME="Ice Lake (10th gen)"; IGPU_GENS="10" ;;
        4e??)            IGPU_NAME="Jasper Lake (Celeron/Pentium)"; IGPU_GENS="" ;;
        45??)            IGPU_NAME="Elkhart Lake (Atom/Celeron)"; IGPU_GENS="" ;;
        9a??)            IGPU_NAME="Tiger Lake (11th gen)"; IGPU_GENS="11"; IGPU_TECH=sriov ;;
        4c??)            IGPU_NAME="Rocket Lake (11th gen)"; IGPU_GENS="11"; IGPU_TECH=sriov ;;
        46d?)            IGPU_NAME="Alder Lake-N (N-series)"; IGPU_GENS="";   IGPU_TECH=sriov ;;
        46??)            IGPU_NAME="Alder Lake (12th gen)"; IGPU_GENS="12"; IGPU_TECH=sriov ;;
        a7??)            IGPU_NAME="Raptor Lake (13th-14th gen)"; IGPU_GENS="13 14"; IGPU_TECH=sriov ;;
        7d??)            IGPU_NAME="Meteor/Arrow Lake (Core Ultra 1-2)"; IGPU_GENS="Ultra"; IGPU_TECH=sriov ;;
        64??)            IGPU_NAME="Lunar Lake (Core Ultra 200V)"; IGPU_GENS="Ultra"; IGPU_TECH=sriov ;;
        b0??)            IGPU_NAME="Panther Lake (Core Ultra 3)"; IGPU_GENS="Ultra"; IGPU_TECH=sriov ;;
        *)               IGPU_NAME="unknown Intel GPU"; IGPU_GENS="" ;;
    esac
    # Braswell (22b?) has no GVT-g support in i915
    [[ "$IGPU_DID" == 22b? ]] && IGPU_TECH=none
    log_debug "iGPU $IGPU_BDF 8086:$IGPU_DID $IGPU_NAME tech=$IGPU_TECH driver=$IGPU_DRIVER vfs=$IGPU_NUMVFS/$IGPU_TOTALVFS"
}

# catalog_lookup DID -> "rom<TAB>min_qemu" of the longest matching ID prefix
catalog_lookup() {
    local did=$1
    [[ -f "$ROM_CATALOG" ]] || return 0
    awk -F'\t' -v d="$did" '
        /^[[:space:]]*(#|$)/ { next }
        { p = tolower($1); if (index(d, p) == 1 && length(p) > best) { best = length(p); r = $2 "\t" ($3 == "" ? 10 : $3) } }
        END { if (best) print r }' "$ROM_CATALOG"
}
default_rom() { catalog_lookup "$IGPU_DID" | cut -f1; }
rom_min_qemu() {   # by ROM name, from the catalog (default 10)
    local q
    q="$(awk -F'\t' -v n="$1" '!/^[[:space:]]*#/ && $2 == n && $3 != "" { print $3; exit }' "$ROM_CATALOG" 2>/dev/null)"
    echo "${q:-10}"
}
rom_expected_sum() { awk -v n="$1" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1; exit }' "$ROM_SUMS" 2>/dev/null; }
rom_sum_state() {   # FILE NAME -> ok | mismatch | unlisted
    local want; want="$(rom_expected_sum "$2")"
    [[ -n "$want" ]] || { echo unlisted; return 0; }
    if [[ "$(sha256sum "$1" | cut -d' ' -f1)" == "$want" ]]; then echo ok; else echo mismatch; fi
}

REALPC=0; REALPC_MODE=""; REALPC_KERNEL=""; REALPC_TAG=""; REALPC_CONTRACT=""
detect_realpc() {
    [[ -f "$REALPC_STATE" ]] || return 0
    REALPC=1
    REALPC_MODE="$(sed -n 's/^INSTALL_MODE=//p' "$REALPC_STATE" | tail -n1)"
    REALPC_KERNEL="$(sed -n 's/^KERNEL_RELEASE=//p' "$REALPC_STATE" | tail -n1)"
    REALPC_TAG="$(sed -n 's/^RELEASE_TAG=//p' "$REALPC_STATE" | tail -n1)"
    REALPC_CONTRACT="$(sed -n 's/^CONTRACT_VERSION=//p' "$REALPC_STATE" | tail -n1)"
}

secure_boot_on() {
    have mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'
}

dkms_sriov_state() {   # prints: built | not-built | absent
    have dkms || { echo absent; return 0; }
    local s; s="$(dkms status i915-sriov-dkms 2>/dev/null || true)"
    [[ -z "$s" ]] && { echo absent; return 0; }
    if grep -F "$KERNEL" <<<"$s" | grep -q installed; then echo built; else echo not-built; fi
}

# ---------------------------------------------------------------- kernel cmdline
boot_style() { if [[ -f "$KERNEL_CMDLINE" ]]; then echo systemd-boot; else echo grub; fi; }

cmdline_get() {
    if [[ "$(boot_style)" == systemd-boot ]]; then head -n1 "$KERNEL_CMDLINE"
    else sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$GRUB_DEFAULT" 2>/dev/null | tail -n1; fi
}

cmdline_put() {
    local new=$1
    if [[ "$(boot_style)" == systemd-boot ]]; then
        file_put "$KERNEL_CMDLINE" <<<"$new"
    elif grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT" 2>/dev/null; then
        file_put "$GRUB_DEFAULT" < <(awk -v v="$new" 'BEGIN{d=0} /^GRUB_CMDLINE_LINUX_DEFAULT=/{ if(!d){print "GRUB_CMDLINE_LINUX_DEFAULT=\"" v "\""; d=1}; next } {print}' "$GRUB_DEFAULT")
    else
        file_put "$GRUB_DEFAULT" < <(readf "$GRUB_DEFAULT"; echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"")
    fi
    [[ "$FILE_CHANGED" == 1 ]] && NEED_BOOT_REFRESH=1
    return 0
}

# params_add TOKEN...  - add/replace by key, record what we added/replaced
params_add() {
    local cur new t key w added replaced out
    cur="$(cmdline_get)"; new="$cur"
    added="$(st_get ADDED_PARAMS)"; replaced="$(st_get REPLACED_PARAMS)"
    for t in "$@"; do
        key="${t%%=*}"
        [[ " $new " == *" $t "* ]] && continue
        out=""
        for w in $new; do
            if [[ "${w%%=*}" == "$key" ]]; then replaced="${replaced:+$replaced }$w"; continue; fi
            out="${out:+$out }$w"
        done
        new="${out:+$out }$t"
        [[ " $added " == *" $t "* ]] || added="${added:+$added }$t"
    done
    [[ "$new" == "$cur" ]] && return 0
    cmdline_put "$new"
    st_set ADDED_PARAMS "$added"; st_set REPLACED_PARAMS "$replaced"
    log_info "Kernel cmdline: $new"
}

# params_remove TOKEN...  - remove our tokens, put back what they replaced
params_remove() {
    local cur new t w key added replaced out keep
    cur="$(cmdline_get)"; added="$(st_get ADDED_PARAMS)"; replaced="$(st_get REPLACED_PARAMS)"
    new="$cur"
    for t in "$@"; do
        [[ " $added " == *" $t "* ]] || continue   # not ours: leave it alone
        out=""; for w in $new; do [[ "$w" == "$t" ]] || out="${out:+$out }$w"; done; new="$out"
        out=""; for w in $added; do [[ "$w" == "$t" ]] || out="${out:+$out }$w"; done; added="$out"
        key="${t%%=*}"; keep=""
        for w in $replaced; do
            if [[ "${w%%=*}" == "$key" ]]; then new="${new:+$new }$w"; else keep="${keep:+$keep }$w"; fi
        done
        replaced="$keep"
    done
    [[ "$new" == "$cur" ]] && return 0
    cmdline_put "$new"
    st_set ADDED_PARAMS "$added"; st_set REPLACED_PARAMS "$replaced"
    log_info "Kernel cmdline: $new"
}

refresh_boot() {
    if [[ "$(boot_style)" == systemd-boot ]]; then
        run proxmox-boot-tool refresh
    else
        run update-grub
        if have proxmox-boot-tool && proxmox-boot-tool status >/dev/null 2>&1; then run proxmox-boot-tool refresh; fi
    fi
}

finish_host_changes() {
    if [[ "$NEED_BOOT_REFRESH" == 1 ]]; then refresh_boot; fi
    if [[ "$NEED_INITRAMFS" == 1 ]]; then run update-initramfs -u -k all; fi
    if [[ "$NEED_BOOT_REFRESH" == 1 || "$NEED_INITRAMFS" == 1 ]]; then
        log_warn "Reboot the host to apply the kernel/module changes"
    fi
}

# ---------------------------------------------------------------- APT safety
# Install only with --no-upgrade and only if nothing held / realpc-owned is touched.
apt_safe_install() {
    local sim held p
    sim="$(apt-get -s install --no-upgrade "$@" 2>&1)" || die "apt-get simulation failed: $sim"
    held="$(apt-mark showhold 2>/dev/null || true)"
    if grep -q '^Remv ' <<<"$sim"; then die "Installing $* would remove packages - refusing"; fi
    for p in $held pve-qemu-kvm pve-edk2-firmware pve-edk2-firmware-ovmf; do
        if grep -qE "^Inst $p( |:)" <<<"$sim"; then die "Installing $* would change $p (held or realpc-owned) - refusing"; fi
    done
    run apt-get install -y --no-upgrade "$@"
}

# ---------------------------------------------------------------- VM helpers
VM_CACHE_ID=""; VM_CACHE=""
vm_config() {
    local vmid=$1
    if [[ "$VM_CACHE_ID" != "$vmid" ]]; then
        VM_CACHE="$(qm config "$vmid" 2>/dev/null)" || die "VM $vmid not found (qm config failed)"
        VM_CACHE_ID="$vmid"
    fi
    printf '%s\n' "$VM_CACHE"
}
vm_get() { vm_config "$1" | awk -v k="$2" 'index($0, k": ")==1 { print substr($0, length(k)+3); exit }'; }
vm_running() { qm status "$1" 2>/dev/null | grep -q 'status: running'; }
vm_list() { qm list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }

# normalise "00:02.1" -> "0000:00:02.1" for every device of a hostpci value
hostpci_bdfs() {
    local v="${1%%,*}" d
    [[ "$v" == mapping=* ]] && return 0
    tr ';' '\n' <<<"$v" | while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        [[ "$d" =~ ^[0-9a-fA-F]{4}: ]] || d="0000:$d"
        echo "${d,,}"
    done
}

# prints "index<TAB>value" for every hostpci of the VM
vm_hostpcis() { vm_config "$1" | sed -n 's/^hostpci\([0-9]\+\): /\1\t/p'; }

vm_free_hostpci() {
    local vmid=$1 i used
    used="$(vm_hostpcis "$vmid" | cut -f1)"
    for i in $(seq 0 15); do grep -qx "$i" <<<"$used" || { echo "$i"; return 0; }; done
    die "VM $vmid has no free hostpci slot"
}

# index of the VM hostpci that already points to BDF (empty if none)
vm_hostpci_for() {
    local vmid=$1 bdf=$2 idx val
    while IFS=$'\t' read -r idx val; do
        [[ -z "$idx" ]] && continue
        if hostpci_bdfs "$val" | grep -qx "$bdf"; then echo "$idx"; return 0; fi
    done < <(vm_hostpcis "$vmid")
}

# VMs (other than $2) that use BDF $1
vms_using() {
    local bdf=$1 skip=${2:-} id idx val
    for id in $(vm_list); do
        [[ "$id" == "$skip" ]] && continue
        VM_CACHE_ID=""
        while IFS=$'\t' read -r idx val; do
            [[ -z "$idx" ]] && continue
            if hostpci_bdfs "$val" | grep -qx "$bdf"; then echo "$id"; break; fi
        done < <(vm_hostpcis "$id")
    done
    VM_CACHE_ID=""
}

is_q35() { [[ "$(vm_get "$1" machine)" == *q35* ]]; }

# our IGD tokens for hostpci index N
igd_tokens() {
    local n=$1 q35=$2 t
    t="-set device.hostpci$n.addr=02.0"
    [[ "$q35" == 1 ]] && t="-set device.hostpci$n.bus=pcie.0 $t"
    printf '%s' "$t -set device.hostpci$n.x-igd-gms=$GMS -set device.hostpci$n.x-igd-opregion=on -set device.hostpci$n.x-igd-legacy-mode=on"
}

# remove our tokens for index N from an args string, keep everything else as is
strip_igd_tokens() {
    local args=$1 n=$2
    args="$(sed -E -e "s/(^| )-set device\.hostpci$n\.(addr|bus|x-igd-[a-z-]+|display|ramfb|driver)=[^ ]+//g" \
        -e "s/(^| )-display egl-headless,rendernode=[^ ]*pci-$IGPU_BDF-render//g" <<<"$args")"
    args="${args#"${args%%[! ]*}"}"; args="${args%"${args##*[! ]}"}"
    printf '%s' "$args"
}

vm_state_dir() { echo "$STATE_DIR/vm/$1"; }
vm_st_get() { readf "$(vm_state_dir "$1")/$2"; }
vm_st_put() { [[ "$DRY_RUN" == 1 ]] && return 0; file_put "$(vm_state_dir "$1")/$2" <<<"$3"; }

# ---------------------------------------------------------------- host steps
host_prepare() {   # [extra modules...]
    params_add intel_iommu=on iommu=pt
    file_put "$MODULES_FILE" < <(printf '%s\n' "# Managed by pve-intel-gpu.sh - removed by --mode revert" vfio vfio_iommu_type1 vfio_pci "$@")
    [[ "$FILE_CHANGED" == 1 ]] && NEED_INITRAMFS=1
    [[ -n "$(st_get HOST_MODE)" ]] || st_set HOST_MODE prepared
    return 0
}

any_vf_assigned() {
    local i bdf
    for i in $(seq 1 7); do
        bdf="${IGPU_BDF%.*}.$i"
        [[ -n "$(vms_using "$bdf")" ]] && { echo "$bdf"; return 0; }
    done
    return 0
}

write_vf_unit() {
    local n=$1
    file_put "$VF_UNIT" <<EOF
# Managed by pve-intel-gpu.sh - removed by --mode revert
[Unit]
Description=Intel iGPU SR-IOV virtual functions (pve-intel-gpu)
After=systemd-modules-load.service
Before=pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo 0 > /sys/bus/pci/devices/$IGPU_BDF/sriov_numvfs; echo $n > /sys/bus/pci/devices/$IGPU_BDF/sriov_numvfs'
ExecStop=/bin/sh -c 'echo 0 > /sys/bus/pci/devices/$IGPU_BDF/sriov_numvfs'

[Install]
WantedBy=multi-user.target
EOF
    if [[ "$FILE_CHANGED" == 1 ]]; then
        UNIT_TOUCHED=1
        if have systemctl; then run systemctl daemon-reload; run systemctl enable "$VF_UNIT_NAME" >/dev/null; fi
    fi
    return 0
}

set_numvfs() {
    local n=$1 f="$SYS_PCI/$IGPU_BDF/sriov_numvfs"
    [[ "$IGPU_NUMVFS" == "$n" ]] && return 0
    if [[ "$IGPU_NUMVFS" != 0 ]]; then
        local used; used="$(any_vf_assigned)"
        [[ -z "$used" ]] || die "VF $used is assigned to a VM; cannot change the VF count from $IGPU_NUMVFS to $n"
    fi
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] echo $n > ${f#"$ROOT"}" >&2; return 0; fi
    VF_RESTORE="$IGPU_NUMVFS"
    [[ "$IGPU_NUMVFS" != 0 ]] && echo 0 >"$f"
    echo "$n" >"$f" || die "Writing $n to sriov_numvfs failed (see dmesg)"
    IGPU_NUMVFS="$n"
    log_ok "SR-IOV: $n VFs enabled"
}

# ---------------------------------------------------------------- vGPU: technology by generation
# VMs whose hostpci points to the whole iGPU: with mdev= (GVT-g) or without (passthrough)
igpu_vms() {   # gvt|passthrough [skip-vmid]
    local kind=$1 skip=${2:-} id idx val
    for id in $(vm_list); do
        [[ "$id" == "$skip" ]] && continue
        VM_CACHE_ID=""
        while IFS=$'\t' read -r idx val; do
            [[ -z "$idx" ]] && continue
            hostpci_bdfs "$val" | grep -qx "$IGPU_BDF" || continue
            if [[ "$val" == *mdev=* ]]; then [[ "$kind" == gvt ]] && echo "$id"
            else [[ "$kind" == passthrough ]] && echo "$id"; fi
            break
        done < <(vm_hostpcis "$id")
    done
    VM_CACHE_ID=""
}

host_vgpu() {
    [[ "$IGPU_PRESENT" == 1 ]] || die "No Intel iGPU at $IGPU_BDF"
    case "$IGPU_TECH" in
        gvt|sriov) ;;
        *) die "$IGPU_NAME (8086:$IGPU_DID) has neither GVT-g (Gen8-9) nor SR-IOV (Gen12+). Only --mode passthrough is possible." ;;
    esac
    local hm users; hm="$(st_get HOST_MODE)"
    if [[ "$hm" == passthrough ]]; then
        users="$(igpu_vms passthrough | xargs)"
        [[ -z "$users" ]] || die "The iGPU is passed through to VM(s) $users. Revert them first."
        log_info "Switching host mode passthrough -> vgpu"
        file_del "$MODPROBE_FILE"; [[ "$FILE_CHANGED" == 1 ]] && NEED_INITRAMFS=1
    fi
    if [[ "$IGPU_TECH" == gvt ]]; then host_gvt; else host_sriov; fi
}

GVT_TYPES_DIR=""
gvt_active() {
    GVT_TYPES_DIR="$SYS_PCI/$IGPU_BDF/mdev_supported_types"
    compgen -G "$GVT_TYPES_DIR/i915-GVTg_*" >/dev/null
}
kvmgt_available() { modinfo -n kvmgt >/dev/null 2>&1; }

host_gvt() {
    kvmgt_available || die "Kernel $KERNEL has no kvmgt module (CONFIG_DRM_I915_GVT_KVMGT); GVT-g is not possible with this kernel."
    host_prepare kvmgt
    st_set HOST_MODE vgpu
    st_set VGPU_TECH gvt
    # GVT-g needs i915 on the host with GuC submission off
    params_add i915.enable_gvt=1 i915.enable_guc=0
    if [[ "$IGPU_DRIVER" != i915 ]]; then
        log_warn "The iGPU is bound to '$IGPU_DRIVER'; GVT-g needs i915 on the host (reboot after this change)"
    fi
    if gvt_active; then
        log_ok "GVT-g active: $(gvt_type_list | tr '\n' ' ')"
    else
        NEED_INITRAMFS=1
        log_warn "GVT-g will be available after a reboot. Then rerun: $SCRIPT_NAME --mode vgpu${VMID:+ --vmid $VMID}${GUEST:+ --guest $GUEST}"
        VGPU_PENDING_REBOOT=1
    fi
}

# "type avail capacity resolution" per type, capacity = free + already created
gvt_type_list() {
    local d t avail created res
    gvt_active || return 0
    for d in "$GVT_TYPES_DIR"/i915-GVTg_*; do
        t="$(basename "$d")"
        avail="$(readf "$d/available_instances")"; [[ "$avail" =~ ^[0-9]+$ ]] || avail=0
        created="$(find "$d/devices" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
        res="$(sed -n 's/^resolution: *//p' "$d/description" 2>/dev/null | head -n1)"
        echo "$t $avail $((avail + created)) ${res:-?}"
    done
}

# VMs configured with GVT-g type T (other than skip)
gvt_configured() {
    local t=$1 skip=${2:-} id n=0
    for id in $(igpu_vms gvt "$skip"); do
        VM_CACHE_ID=""
        vm_config "$id" | grep -qE "^hostpci[0-9]+: .*mdev=$t(,|$)" && n=$((n + 1))
    done
    VM_CACHE_ID=""
    echo "$n"
}

gvt_pick_type() {   # sets GVT_PICKED
    local vmid=$1 t cap line want
    GVT_PICKED=""
    gvt_active || die "GVT-g is not active (no mdev types on $IGPU_BDF). Reboot after --mode vgpu, check 'dmesg | grep -i gvt'."
    if [[ -n "$GVT_TYPE" ]]; then
        line="$(gvt_type_list | awk -v t="$GVT_TYPE" '$1 == t')"
        [[ -n "$line" ]] || die "GVT-g type $GVT_TYPE does not exist. Available: $(gvt_type_list | awk '{print $1}' | xargs)"
        cap="$(awk '{print $3}' <<<"$line")"
        [[ "$(gvt_configured "$GVT_TYPE" "$vmid")" -lt "$cap" ]] \
            || log_warn "All $cap $GVT_TYPE slots are configured in other VMs: they cannot all run at once"
        GVT_PICKED="$GVT_TYPE"; return 0
    fi
    for want in V5_4 V5_2 V5_8 V5_1; do
        t="i915-GVTg_$want"
        line="$(gvt_type_list | awk -v t="$t" '$1 == t')"
        [[ -n "$line" ]] || continue
        cap="$(awk '{print $3}' <<<"$line")"
        if [[ "$(gvt_configured "$t" "$vmid")" -lt "$cap" ]]; then GVT_PICKED="$t"; return 0; fi
    done
    die "No free GVT-g slot: every type is fully configured in other VMs. Free one (--mode revert --vmid N) or pass --gvt-type."
}

host_sriov() {
    host_prepare
    st_set HOST_MODE vgpu
    st_set VGPU_TECH sriov
    if [[ "$IGPU_TOTALVFS" -gt 0 && ( "$IGPU_DRIVER" == i915 || "$IGPU_DRIVER" == xe ) ]]; then
        local n="${NUMVFS:-7}"; [[ "$n" -gt "$IGPU_TOTALVFS" ]] && n="$IGPU_TOTALVFS"
        set_numvfs "$n"
        write_vf_unit "$n"
        st_set NUMVFS "$n"
        return 0
    fi
    # SR-IOV not available yet: driver/kernel side
    secure_boot_on && log_warn "Secure Boot is enabled: an unsigned DKMS module will not load (enrol a MOK or disable Secure Boot)"
    local dk; dk="$(dkms_sriov_state)"
    if [[ "$dk" == absent ]]; then
        [[ -n "$DKMS_DEB" ]] || die "SR-IOV is not available with the current i915 driver. Install i915-sriov-dkms (https://github.com/strongtz/i915-sriov-dkms/releases) or pass --dkms-deb FILE, then rerun."
        [[ -f "$DKMS_DEB" ]] || die "No such file: $DKMS_DEB"
        [[ -d "/lib/modules/$KERNEL/build" ]] || apt_safe_install "proxmox-headers-$KERNEL"
        apt_safe_install "$(realpath "$DKMS_DEB")"
    elif [[ "$dk" == not-built ]]; then
        log_warn "i915-sriov-dkms is installed but not built for $KERNEL - check 'dkms status' / headers"
    fi
    local n="${NUMVFS:-7}"
    params_add i915.enable_guc=3 "i915.max_vfs=$n" module_blacklist=xe
    st_set NUMVFS "$n"
    write_vf_unit "$n"
    NEED_INITRAMFS=1
    log_warn "SR-IOV will be available after a reboot. Then rerun: $SCRIPT_NAME --mode vgpu${VMID:+ --vmid $VMID}${GUEST:+ --guest $GUEST}"
    VGPU_PENDING_REBOOT=1
}
VGPU_PENDING_REBOOT=0

host_passthrough() {
    [[ "$IGPU_PRESENT" == 1 ]] || die "No Intel iGPU at $IGPU_BDF"
    local hm used; hm="$(st_get HOST_MODE)"
    if [[ "$hm" == vgpu ]]; then
        used="$(any_vf_assigned)"
        [[ -z "$used" ]] || die "VF $used is still assigned to a VM. Revert vGPU VMs first."
        used="$(igpu_vms gvt | xargs)"
        [[ -z "$used" ]] || die "GVT-g is configured in VM(s) $used. Revert vGPU VMs first."
        log_info "Switching host mode vgpu -> passthrough"
        if [[ "$IGPU_NUMVFS" != 0 ]]; then set_numvfs 0 || true; fi
        if [[ -e "$VF_UNIT" ]]; then
            if have systemctl; then run systemctl disable "$VF_UNIT_NAME" >/dev/null 2>&1 || true; fi
            file_del "$VF_UNIT"; UNIT_TOUCHED=1
        fi
        params_remove i915.enable_guc=3 "i915.max_vfs=$(st_get NUMVFS)" module_blacklist=xe i915.enable_gvt=1 i915.enable_guc=0
        st_del VGPU_TECH
    fi
    host_prepare
    file_put "$MODPROBE_FILE" <<EOF
# Managed by pve-intel-gpu.sh - removed by --mode revert
# Full passthrough: bind the iGPU 8086:$IGPU_DID to vfio-pci before i915/xe
options vfio-pci ids=8086:$IGPU_DID disable_vga=1
softdep i915 pre: vfio-pci
softdep xe pre: vfio-pci
EOF
    [[ "$FILE_CHANGED" == 1 ]] && NEED_INITRAMFS=1
    st_set HOST_MODE passthrough
    if [[ "$IGPU_DRIVER" != vfio-pci ]]; then
        log_warn "The iGPU is bound to '$IGPU_DRIVER' now; after a reboot it will be on vfio-pci (host console output will stop)"
    fi
    return 0
}

# ---------------------------------------------------------------- ROM
rom_valid() { [[ "$(head -c2 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == 55aa ]]; }

# resolve_rom: find the ROM without changing anything.
# Sets ROM_NAME (relative to /usr/share/kvm), ROM_SRC (file to install, may be
# empty when the ROM is already there) and ROM_MINQEMU.
ROM_NAME=""; ROM_SRC=""; ROM_MINQEMU=10
resolve_rom() {
    local name src="" st
    if [[ -n "$ROM" && -f "$ROM" ]]; then
        src="$ROM"; name="$(basename "$ROM")"
        rom_valid "$src" || die "$src is not a PCI option ROM (no 55AA signature)"
        log_warn "ROM $src was given explicitly: its checksum is not verified (add it with --mode rom-add to verify)"
    else
        name="${ROM:-$(default_rom)}"
        [[ -n "$name" ]] || die "No ROM in ${ROM_CATALOG} for $IGPU_NAME (8086:$IGPU_DID). Add one: --mode rom-add --rom FILE --ids $IGPU_DID"
        [[ "$name" != */* ]] || die "No such ROM file: $name"
        if [[ -f "$ROMS_DIR/$name" ]]; then src="$ROMS_DIR/$name"
        elif [[ ! -f "$KVM_ROM_DIR/$name" ]]; then
            die "ROM $name is in the catalog but neither in $ROMS_DIR nor in ${KVM_ROM_DIR#"$ROOT"}"
        fi
        local file="${src:-$KVM_ROM_DIR/$name}"
        rom_valid "$file" || die "$file is not a PCI option ROM (no 55AA signature)"
        st="$(rom_sum_state "$file" "$name")"
        case "$st" in
            ok) log_debug "ROM $name: checksum OK" ;;
            mismatch) [[ "$FORCE" == 1 ]] || die "ROM $file does not match $ROM_SUMS (use --force to override)"
                      log_warn "ROM $file does not match $ROM_SUMS - used because of --force" ;;
            unlisted) [[ "$FORCE" == 1 ]] || die "ROM $name is not listed in $ROM_SUMS (add it with --mode rom-add, or --force)"
                      log_warn "ROM $name is not in $ROM_SUMS - used because of --force" ;;
        esac
    fi
    ROM_NAME="$name"; ROM_SRC="$src"; ROM_MINQEMU="$(rom_min_qemu "$name")"
}

# rom-add: copy a ROM into bios/, record its checksum and the PCI IDs it serves
mode_rom_add() {
    local name want id tmp
    [[ -f "$ROM" ]] || die "No such file: $ROM"
    rom_valid "$ROM" || die "$ROM is not a PCI option ROM (no 55AA signature)"
    name="$(basename "$ROM")"
    [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]] || die "ROM file name must be simple (letters, digits, . _ + -)"
    want="$(sha256sum "$ROM" | cut -d' ' -f1)"
    mkdir -p "$ROMS_DIR"
    if [[ "$(realpath "$ROM")" != "$(realpath -m "$ROMS_DIR/$name")" ]]; then
        if [[ -f "$ROMS_DIR/$name" ]] && ! cmp -s "$ROM" "$ROMS_DIR/$name"; then
            confirm "$ROMS_DIR/$name exists and differs. Replace it?" || exit 1
        fi
        run cp -f "$ROM" "$ROMS_DIR/$name"
    fi
    tmp="$(mktemp)"
    { awk -v n="$name" '{ f = $2; sub(/^\*/, "", f) } f != n' "$ROM_SUMS" 2>/dev/null; printf '%s  %s\n' "$want" "$name"; } \
        | sort -k2 >"$tmp"
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] $ROM_SUMS: $want  $name" >&2; else cat "$tmp" >"$ROM_SUMS"; fi
    [[ -f "$ROM_CATALOG" ]] || printf '# PCI device ID prefix\tROM\tmin QEMU\tsource\n' >"$ROM_CATALOG"
    for id in $ROM_IDS; do
        id="${id,,}"
        awk -F'\t' -v i="$id" '!/^[[:space:]]*#/ && tolower($1) == i' "$ROM_CATALOG" | grep -q . \
            && { awk -F'\t' -v i="$id" '/^[[:space:]]*#/ || tolower($1) != i' "$ROM_CATALOG" >"$tmp"
                 [[ "$DRY_RUN" == 1 ]] || cat "$tmp" >"$ROM_CATALOG"; }
        if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] $ROM_CATALOG: $id -> $name" >&2
        else printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$ROM_QEMU" "${ROM_SOURCE:-added $(date +%F)}" >>"$ROM_CATALOG"; fi
    done
    rm -f "$tmp"
    log_ok "ROM $name added (sha256 $want) for IDs: $ROM_IDS"
}

ensure_rom() {
    [[ -n "$ROM_NAME" ]] || resolve_rom
    local name="$ROM_NAME" src="$ROM_SRC" dst owned
    dst="$KVM_ROM_DIR/$name"
    if [[ -n "$src" ]]; then
        if [[ -f "$dst" ]] && ! cmp -s "$src" "$dst"; then
            owned="$(st_get "ROM_OWNED_$name")"
            [[ -n "$owned" && "$(sha256sum "$dst" | cut -d' ' -f1)" == "$owned" ]] \
                || die "${dst#"$ROOT"} exists, differs and was not installed by this tool. Remove it or rename your ROM."
        fi
        if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
            file_put "$dst" <"$src"
            st_set "ROM_OWNED_$name" "$(sha256sum "$src" | cut -d' ' -f1)"
            log_info "ROM installed: ${dst#"$ROOT"}"
        fi
    fi
}

# ---------------------------------------------------------------- VM steps
# everything that can refuse, checked before the host is touched
vm_passthrough_precheck() {
    local vmid=$1 i
    vm_config "$vmid" >/dev/null
    [[ "$(vm_get "$vmid" bios)" == ovmf ]] || die "VM $vmid uses SeaBIOS. The ROM needs OVMF (bios: ovmf + efidisk). Changing it would break an installed guest, so do it yourself first."
    for i in $(seq 1 7); do
        [[ -z "$(vm_hostpci_for "$vmid" "${IGPU_BDF%.*}.$i")" ]] || die "VM $vmid has a vGPU VF. Revert it first (--mode revert --vmid $vmid)."
    done
    local gi; gi="$(vm_hostpci_for "$vmid" "$IGPU_BDF")"
    if [[ -n "$gi" && "$(vm_get "$vmid" "hostpci$gi")" == *mdev=* ]]; then
        die "VM $vmid has a GVT-g vGPU. Revert it first (--mode revert --vmid $vmid)."
    fi
    [[ -z "$(igpu_vms gvt | xargs)" ]] || die "GVT-g is configured in VM(s) $(igpu_vms gvt | xargs); full passthrough would take the iGPU away from them."
    resolve_rom
    if [[ "$QEMU_MAJOR" -lt "$ROM_MINQEMU" && "$FORCE" != 1 ]]; then
        die "QEMU $QEMU_VERSION: ROM $ROM_NAME needs QEMU >= $ROM_MINQEMU. Use --force to try anyway."
    fi
}

vm_passthrough() {
    local vmid=$1 idx rom q35=0 args new others
    vm_passthrough_precheck "$vmid"
    others="$(vms_using "$IGPU_BDF" "$vmid" | xargs)"
    [[ -z "$others" ]] || log_warn "The iGPU is also configured in VM(s) $others - only one of them can run at a time"
    is_q35 "$vmid" && q35=1
    if [[ "$REALPC" == 1 && "$q35" != 1 ]]; then
        log_warn "realpc is installed and its configvm forces q35; keep the VM on q35"
    fi
    [[ "$q35" == 1 ]] && log_warn "q35: the iGPU is placed on pcie.0 at 00:02.0 (bus=pcie.0). AICodo recommends i440fx; q35 works with QEMU >= 10 but verify."
    ensure_rom; rom="$ROM_NAME"

    idx="$(vm_hostpci_for "$vmid" "$IGPU_BDF")"
    [[ -n "$idx" ]] || idx="$(vm_free_hostpci "$vmid")"
    vm_set "$vmid" "hostpci$idx" "$IGPU_BDF,romfile=$rom"
    vm_st_put "$vmid" hostpci "$idx"
    if [[ "$AUDIO" == 1 ]]; then
        if [[ -e "$SYS_PCI/$AUDIO_BDF" ]]; then
            local aidx; aidx="$(vm_hostpci_for "$vmid" "$AUDIO_BDF")"
            if [[ -z "$aidx" ]]; then aidx="$(vm_free_hostpci "$vmid")"; vm_set "$vmid" "hostpci$aidx" "$AUDIO_BDF"; fi
            vm_st_put "$vmid" hostpci_audio "$aidx"
        else log_warn "No audio device at $AUDIO_BDF"; fi
    fi

    # vga: remember the original once, then none
    if [[ -z "$(vm_st_get "$vmid" vga)" ]]; then
        local oldvga; oldvga="$(vm_get "$vmid" vga)"
        vm_st_put "$vmid" vga "${oldvga:-__ABSENT__}"
    fi
    vm_set "$vmid" vga none

    # args: replace only our tokens, keep the rest (realpc ACPI/SMBIOS, user tokens)
    local frag; frag="$(igd_tokens "$idx" "$q35")"
    vm_st_put "$vmid" args "$frag"
    # contract: the same fragment in the shared args.d, so other tools that
    # rebuild the args line (realpc configvm) keep it
    [[ "$DRY_RUN" == 1 ]] || file_put "$ARGS_D/$vmid/$ARGS_FRAGMENT_NAME" <<<"$frag"
    args="$(strip_igd_tokens "$(vm_get "$vmid" args)" "$idx")"
    new="${args:+$args }$frag"
    vm_set "$vmid" args "$new"
    vm_running "$vmid" && log_warn "VM $vmid is running: the changes apply after a full stop/start"
    log_ok "VM $vmid: iGPU passthrough configured (hostpci$idx, ROM $rom)"
}

vm_reapply() {
    local vmid=$1 idx frag args
    idx="$(vm_st_get "$vmid" hostpci)"; frag="$(vm_st_get "$vmid" args)"
    [[ -n "$idx" && -n "$frag" ]] || die "VM $vmid has no passthrough/GVT-g args state from this tool"
    [[ "$(vm_get "$vmid" "hostpci$idx")" == "$IGPU_BDF"* ]] || die "hostpci$idx of VM $vmid no longer points to $IGPU_BDF; run --mode passthrough --vmid $vmid"
    args="$(strip_igd_tokens "$(vm_get "$vmid" args)" "$idx")"
    vm_set "$vmid" args "${args:+$args }$frag"
    [[ -n "$(vm_st_get "$vmid" vga)" ]] && vm_set "$vmid" vga none
    [[ "$DRY_RUN" == 1 ]] || file_put "$ARGS_D/$vmid/$ARGS_FRAGMENT_NAME" <<<"$frag"
    log_ok "VM $vmid: our args (and vga) reapplied"
}

vm_vgpu() {
    local vmid=$1
    vm_config "$vmid" >/dev/null
    if [[ "$IGPU_TECH" == gvt ]]; then vm_gvt "$vmid"; else vm_sriov "$vmid"; fi
    vm_st_put "$vmid" tech "$IGPU_TECH"
    [[ -z "$GUEST" ]] || vm_st_put "$vmid" guest "$GUEST"
    guest_hints
}

# display default: the vGPU is the screen for android/linux with GVT-g
display_mode() {
    if [[ -n "$DISPLAY_MODE" ]]; then echo "$DISPLAY_MODE"
    elif [[ "$IGPU_TECH" == gvt && ( "$GUEST" == android || "$GUEST" == linux ) ]]; then echo vgpu
    else echo console; fi
}

gvt_tokens() {   # N display
    local n=$1 t
    t="-set device.hostpci$n.x-igd-opregion=on"
    if [[ "$2" == vgpu ]]; then
        t="$t -set device.hostpci$n.display=on -set device.hostpci$n.ramfb=on -set device.hostpci$n.driver=vfio-pci-nohotplug"
        t="$t -display egl-headless,rendernode=/dev/dri/by-path/pci-$IGPU_BDF-render"
    fi
    printf '%s' "$t"
}

vm_gvt() {
    local vmid=$1 idx val i disp frag args
    idx="$(vm_hostpci_for "$vmid" "$IGPU_BDF")"
    if [[ -n "$idx" ]]; then
        val="$(vm_get "$vmid" "hostpci$idx")"
        [[ "$val" == *mdev=* ]] || die "VM $vmid has the whole iGPU passed through (hostpci$idx). Revert it first."
    fi
    for i in $(seq 1 7); do
        [[ -z "$(vm_hostpci_for "$vmid" "${IGPU_BDF%.*}.$i")" ]] || die "VM $vmid has an SR-IOV VF. Revert it first."
    done
    gvt_pick_type "$vmid"
    [[ -n "$idx" ]] || idx="$(vm_free_hostpci "$vmid")"
    vm_set "$vmid" "hostpci$idx" "$IGPU_BDF,mdev=$GVT_PICKED"
    vm_st_put "$vmid" hostpci "$idx"
    disp="$(display_mode)"
    if [[ "$disp" == vgpu ]]; then
        if [[ -z "$(vm_st_get "$vmid" vga)" ]]; then
            local oldvga; oldvga="$(vm_get "$vmid" vga)"
            vm_st_put "$vmid" vga "${oldvga:-__ABSENT__}"
        fi
        vm_set "$vmid" vga none
        [[ "$(vm_get "$vmid" bios)" == ovmf ]] || log_warn "VM $vmid uses SeaBIOS: the ramfb boot screen needs OVMF; the guest i915 screen appears once the driver loads"
    fi
    frag="$(gvt_tokens "$idx" "$disp")"
    vm_st_put "$vmid" args "$frag"
    [[ "$DRY_RUN" == 1 ]] || file_put "$ARGS_D/$vmid/$ARGS_FRAGMENT_NAME" <<<"$frag"
    args="$(strip_igd_tokens "$(vm_get "$vmid" args)" "$idx")"
    vm_set "$vmid" args "${args:+$args }$frag"
    vm_running "$vmid" && log_warn "VM $vmid is running: the vGPU appears after a full stop/start"
    log_ok "VM $vmid: GVT-g $GVT_PICKED (hostpci$idx), display: $disp"
}

guest_hints() {
    [[ "$GUEST" == android ]] || return 0
    log_info "BlissOS / Android-x86 guest:"
    log_info "  - boot entry: no 'nomodeset'; keep the default drm hardware composer"
    log_info "  - hardware video: add FFMPEG_CODEC2_PREFER=1, do not set FFMPEG_HWACCEL_DISABLE"
    if [[ "$IGPU_TECH" == gvt ]]; then
        log_info "  - GVT-g guest: i915 detects the vGPU itself; GuC/HuC are not used inside a vGPU"
        [[ "$(display_mode)" == vgpu ]] && log_info "  - screen: Proxmox console (noVNC) shows the vGPU output; first boot can take a minute"
    else
        log_warn "  - SR-IOV: the guest kernel needs the i915 SR-IOV VF driver (i915-sriov-dkms built into the guest)."
        log_warn "    Stock BlissOS kernels may not have it; without it Android starts without GPU acceleration."
        log_info "  - a VF has no display output: keep the VM console vga and use scrcpy/adb for the screen"
    fi
}

vm_sriov() {
    local vmid=$1 n i bdf idx free="" q35=0
    [[ -z "$(vm_hostpci_for "$vmid" "$IGPU_BDF")" ]] || die "VM $vmid has the whole iGPU passed through (or GVT-g). Revert it first."
    for i in $(seq 1 7); do
        bdf="${IGPU_BDF%.*}.$i"
        idx="$(vm_hostpci_for "$vmid" "$bdf")"
        if [[ -n "$idx" ]]; then log_ok "VM $vmid already has VF $bdf (hostpci$idx)"; return 0; fi
    done
    n="${IGPU_NUMVFS:-0}"
    [[ "$n" -gt 0 ]] || die "No VFs are enabled on the host"
    if [[ -n "$VF" ]]; then
        [[ "$VF" -le "$n" ]] || die "VF $VF does not exist (only $n enabled)"
        bdf="${IGPU_BDF%.*}.$VF"
        [[ -z "$(vms_using "$bdf" "$vmid")" ]] || log_warn "VF $bdf is also configured in VM(s) $(vms_using "$bdf" "$vmid" | xargs)"
        free="$bdf"
    else
        for i in $(seq 1 "$n"); do
            bdf="${IGPU_BDF%.*}.$i"
            if [[ -z "$(vms_using "$bdf" "$vmid")" ]]; then free="$bdf"; break; fi
        done
        [[ -n "$free" ]] || die "All $n VFs are already assigned to VMs"
    fi
    is_q35 "$vmid" && q35=1
    idx="$(vm_free_hostpci "$vmid")"
    vm_set "$vmid" "hostpci$idx" "$free$( [[ "$q35" == 1 ]] && echo ",pcie=1" )"
    vm_st_put "$vmid" hostpci "$idx"
    vm_running "$vmid" && log_warn "VM $vmid is running: the VF appears after a full stop/start"
    log_ok "VM $vmid: vGPU VF $free (hostpci$idx). Guest needs the Intel graphics driver."
}

vm_revert() {
    local vmid=$1 idx aidx val vga args
    vm_config "$vmid" >/dev/null
    idx="$(vm_st_get "$vmid" hostpci)"; aidx="$(vm_st_get "$vmid" hostpci_audio)"
    [[ -n "$idx" ]] || { log_info "VM $vmid: nothing to revert"; return 0; }
    val="$(vm_get "$vmid" "hostpci$idx")"
    if [[ "$val" == "${IGPU_BDF%.*}."* ]]; then vm_set "$vmid" "hostpci$idx" ""
    elif [[ -n "$val" ]]; then log_warn "VM $vmid: hostpci$idx was changed by someone else ($val) - left as is"; fi
    if [[ -n "$aidx" && "$(vm_get "$vmid" "hostpci$aidx")" == "$AUDIO_BDF"* ]]; then vm_set "$vmid" "hostpci$aidx" ""; fi
    args="$(vm_get "$vmid" args)"
    if [[ -n "$args" ]]; then vm_set "$vmid" args "$(strip_igd_tokens "$args" "$idx")"; fi
    vga="$(vm_st_get "$vmid" vga)"
    if [[ -n "$vga" && "$(vm_get "$vmid" vga)" == none ]]; then
        if [[ "$vga" == __ABSENT__ ]]; then vm_set "$vmid" vga ""; else vm_set "$vmid" vga "$vga"; fi
    fi
    local d; d="$(vm_state_dir "$vmid")"
    local f; for f in hostpci hostpci_audio vga args tech guest; do file_del "$d/$f"; done
    file_del "$ARGS_D/$vmid/$ARGS_FRAGMENT_NAME"
    log_ok "VM $vmid: our changes removed"
}

host_revert() {
    local users="" i bdf
    users="$(vms_using "$IGPU_BDF" | xargs)"
    for i in $(seq 1 7); do bdf="${IGPU_BDF%.*}.$i"; users="$users $(vms_using "$bdf" | xargs)"; done
    users="$(xargs <<<"$users")"
    [[ -z "$users" ]] || die "VM(s) $users still use the iGPU/VFs. Run --mode revert --vmid N for each first."
    if [[ "$IGPU_NUMVFS" != 0 ]]; then set_numvfs 0; fi
    if [[ -e "$VF_UNIT" ]]; then
        if have systemctl; then run systemctl disable "$VF_UNIT_NAME" >/dev/null 2>&1 || true; fi
        file_del "$VF_UNIT"; UNIT_TOUCHED=1
        have systemctl && run systemctl daemon-reload
    fi
    file_del "$MODPROBE_FILE"; [[ "$FILE_CHANGED" == 1 ]] && NEED_INITRAMFS=1
    file_del "$MODULES_FILE"; [[ "$FILE_CHANGED" == 1 ]] && NEED_INITRAMFS=1
    local added; added="$(st_get ADDED_PARAMS)"
    # shellcheck disable=SC2086
    [[ -n "$added" ]] && params_remove $added
    local k name sum
    while IFS= read -r k; do
        name="${k#ROM_OWNED_}"; sum="$(st_get "$k")"
        if [[ -f "$KVM_ROM_DIR/$name" && "$(sha256sum "$KVM_ROM_DIR/$name" | cut -d' ' -f1)" == "$sum" ]]; then
            file_del "$KVM_ROM_DIR/$name"
        fi
        st_del "$k"
    done < <(sed -n 's/^\(ROM_OWNED_[^=]*\)=.*/\1/p' "$STATE_FILE" 2>/dev/null)
    st_del HOST_MODE; st_del NUMVFS; st_del VGPU_TECH
    log_info "Installed packages (e.g. i915-sriov-dkms) are not removed; remove them with apt if wanted"
}

# ---------------------------------------------------------------- check
_ck() { printf '  %-5s %s\n' "$1" "$2"; }

smbios_cpu_of() {   # CPU name from "-smbios type=4,...,version=..." in args
    local s="${1#*-smbios type=4,}"
    [[ "$s" == "$1" ]] && return 0
    s="${s%% -*}"
    sed -n 's/.*version="\([^"]*\)".*/\1/p; t; s/.*version=\([^,]*\).*/\1/p' <<<"$s"
}

smbios_matches() {   # $1 = CPU name; uses IGPU_GENS
    local cpu=$1 g
    [[ -z "$IGPU_GENS" || -z "$cpu" ]] && return 0
    for g in $IGPU_GENS; do
        if [[ "$g" == Ultra ]]; then [[ "$cpu" == *Ultra* ]] && return 0
        else [[ "$cpu" =~ (^|[^0-9])${g}th\ Gen ]] && return 0; fi
    done
    return 1
}

mode_check() {
    local running; running="$(tr ' ' '\n' <"$PROC_CMDLINE" 2>/dev/null | xargs || true)"
    echo "Host"
    _ck "" "PVE $PVE_VERSION, QEMU $QEMU_VERSION, kernel $KERNEL, boot: $(boot_style)"
    if [[ "$QEMU_MAJOR" -ge 10 ]]; then _ck OK "QEMU >= 10 (AICodo ROMs supported)"; else _ck WARN "QEMU < 10: ROM passthrough not supported"; fi
    if [[ " $running " == *" intel_iommu=on "* ]] || [[ -d "$ROOT/sys/kernel/iommu_groups/0" ]]; then _ck OK "IOMMU active"
    else _ck WARN "IOMMU not active (run --mode prepare, then reboot)"; fi
    local p; for p in $(st_get ADDED_PARAMS); do
        [[ " $running " == *" $p "* ]] || _ck WARN "Kernel parameter $p is configured but not active - reboot needed"
    done
    secure_boot_on && _ck WARN "Secure Boot enabled (DKMS / realpc strong modules will not load unsigned)"
    _ck "" "Host mode (this tool): $(st_get HOST_MODE | grep . || echo none)"

    echo "iGPU"
    if [[ "$IGPU_PRESENT" != 1 ]]; then _ck WARN "No Intel display device at $IGPU_BDF"
    else
        _ck OK "8086:$IGPU_DID $IGPU_NAME, driver: $IGPU_DRIVER"
        local rn rf; rn="$(default_rom)"
        if [[ -z "$rn" ]]; then _ck WARN "ROM for passthrough: none in catalog (--mode rom-add)"
        else
            rf="$ROMS_DIR/$rn"; [[ -f "$rf" ]] || rf="$KVM_ROM_DIR/$rn"
            if [[ ! -f "$rf" ]]; then _ck WARN "ROM $rn: file missing"
            else case "$(rom_sum_state "$rf" "$rn")" in
                ok) _ck OK "ROM $rn (QEMU >= $(rom_min_qemu "$rn")), checksum OK" ;;
                mismatch) _ck WARN "ROM $rn: checksum MISMATCH with bios/SHA256SUMS" ;;
                *) _ck WARN "ROM $rn: not listed in bios/SHA256SUMS" ;;
            esac; fi
        fi
        case "$IGPU_TECH" in
            gvt)
                _ck OK "vGPU technology: GVT-g (Gen8-9)"
                if kvmgt_available; then _ck OK "kvmgt module available"; else _ck WARN "kvmgt module missing in kernel $KERNEL"; fi
                if gvt_active; then
                    local t a c r
                    while read -r t a c r; do _ck OK "GVT-g type $t: $a free of $c, $r, configured in $(gvt_configured "$t") VM(s)"; done < <(gvt_type_list)
                else _ck WARN "GVT-g not active (run --mode vgpu, then reboot)"; fi ;;
            sriov)
                _ck OK "vGPU technology: SR-IOV (Gen12+)"
                if [[ "$IGPU_TOTALVFS" -gt 0 ]]; then _ck OK "SR-IOV: $IGPU_NUMVFS of $IGPU_TOTALVFS VFs enabled"
                else _ck "" "SR-IOV: not available with the current driver (i915-sriov-dkms: $(dkms_sriov_state))"; fi ;;
            *) _ck WARN "vGPU technology: none for this generation (neither GVT-g nor SR-IOV); only passthrough" ;;
        esac
    fi

    echo "realpc-clean-build"
    if [[ "$REALPC" == 1 ]]; then
        _ck OK "installed: mode=${REALPC_MODE:-unknown} release=${REALPC_TAG:-unknown}"
        if [[ "$REALPC_MODE" == strong && -n "$REALPC_KERNEL" && "$REALPC_KERNEL" != "$KERNEL" ]]; then
            _ck WARN "kvm.ko built for $REALPC_KERNEL, running $KERNEL: run realpc-setup.sh --mode update"
        fi
        apt-mark showhold 2>/dev/null | grep -q '^pve-qemu-kvm$' && _ck OK "pve-qemu-kvm is held (this tool never upgrades it)"
        if [[ "$REALPC_CONTRACT" == "$CONTRACT_VERSION" ]]; then _ck OK "host-tools contract v$CONTRACT_VERSION: configvm keeps our args and vga"
        elif [[ -z "$REALPC_CONTRACT" ]]; then _ck WARN "realpc without the host-tools contract: after every configvm run --mode reapply --vmid N"
        else _ck WARN "realpc contract v$REALPC_CONTRACT, ours v$CONTRACT_VERSION: update the older tool"; fi
    else _ck "" "not installed"; fi

    echo "VMs"
    if [[ -z "$ROOT" && "$(id -u)" != 0 ]]; then _ck "" "(run as root to inspect VM configs)"; return 0; fi
    local id idx val bdf any=0 cpu
    for id in $(vm_list); do
        VM_CACHE_ID=""
        while IFS=$'\t' read -r idx val; do
            [[ -z "$idx" ]] && continue
            for bdf in $(hostpci_bdfs "$val"); do
                [[ "$bdf" == "${IGPU_BDF%.*}."* ]] || continue
                any=1
                if [[ "$bdf" == "$IGPU_BDF" && "$val" == *mdev=* ]]; then
                    _ck "" "VM $id: GVT-g vGPU (hostpci$idx: $val)"
                    if [[ -n "$(vm_st_get "$id" args)" ]] && [[ "$(vm_get "$id" args)" != *"$(vm_st_get "$id" args)"* ]]; then
                        _ck WARN "VM $id: vGPU args are missing (args line was rewritten) -> --mode reapply --vmid $id"
                    fi
                    if [[ -n "$(vm_st_get "$id" vga)" && "$(vm_get "$id" vga)" != none ]]; then
                        _ck WARN "VM $id: vga is '$(vm_get "$id" vga)', expected none for the vGPU screen -> --mode reapply --vmid $id"
                    fi
                    [[ "$(grep -o -- '-display egl-headless' <<<"$(vm_get "$id" args)" | wc -l | tr -d ' ')" -le 1 ]] \
                        || _ck WARN "VM $id: -display egl-headless appears twice in args (QEMU will refuse) -> --mode reapply --vmid $id"
                elif [[ "$bdf" == "$IGPU_BDF" ]]; then
                    _ck "" "VM $id: full passthrough (hostpci$idx: $val)"
                    [[ "$(vm_get "$id" vga)" == none ]] || _ck WARN "VM $id: vga is '$(vm_get "$id" vga)', expected none (realpc configvm resets it) -> --mode reapply --vmid $id"
                    if [[ -n "$(vm_st_get "$id" args)" ]] && [[ "$(vm_get "$id" args)" != *"$(vm_st_get "$id" args)"* ]]; then
                        _ck WARN "VM $id: IGD args are missing (args line was rewritten) -> --mode reapply --vmid $id"
                    fi
                    [[ "$(vm_get "$id" bios)" == ovmf ]] || _ck WARN "VM $id: not OVMF"
                else
                    _ck "" "VM $id: vGPU VF $bdf (hostpci$idx)"
                    [[ -e "$SYS_PCI/$bdf" ]] || _ck WARN "VM $id: VF $bdf does not exist now (VFs not enabled?)"
                fi
                cpu="$(smbios_cpu_of "$(vm_get "$id" args)")"
                smbios_matches "$cpu" || _ck WARN "VM $id: SMBIOS CPU '$cpu' does not match the iGPU generation ($IGPU_NAME) - inconsistent hardware profile"
            done
        done < <(vm_hostpcis "$id")
    done
    [[ "$any" == 1 ]] || _ck "" "no VM uses the iGPU"
    return 0
}

# ---------------------------------------------------------------- main
main() {
    parse_args "$@"
    log_debug "=== $SCRIPT_NAME $VERSION mode=$MODE vmid=${VMID:-none} dry-run=$DRY_RUN ==="
    detect_versions
    detect_igpu
    detect_realpc

    if [[ "$MODE" == check ]]; then mode_check; return 0; fi
    if [[ "$MODE" == rom-add ]]; then mode_rom_add; return 0; fi

    need_root
    have qm || [[ -n "$ROOT" ]] || die "qm not found - this is not a Proxmox VE host"
    take_lock
    case "$MODE" in
        prepare)     confirm "Enable IOMMU and vfio modules on this host?" || exit 0 ;;
        vgpu)        confirm "Configure vGPU ($IGPU_TECH) for $IGPU_NAME${VMID:+ and give VM $VMID a vGPU}?" || exit 0 ;;
        passthrough) confirm "Bind the iGPU to vfio-pci (host loses iGPU output)${VMID:+ and pass it to VM $VMID}?" || exit 0 ;;
        revert)      confirm "Remove pve-intel-gpu changes${VMID:+ from VM $VMID}${VMID:- from the host}?" || exit 0 ;;
        reapply)     : ;;
    esac

    if [[ "$MODE" == passthrough && -n "$VMID" ]]; then vm_passthrough_precheck "$VMID"; fi
    txn_begin
    st_set CONTRACT_VERSION "$CONTRACT_VERSION"
    case "$MODE" in
        prepare)     host_prepare ;;
        vgpu)        host_vgpu
                     if [[ -n "$VMID" && "$VGPU_PENDING_REBOOT" != 1 ]]; then vm_vgpu "$VMID"; fi ;;
        passthrough) host_passthrough
                     if [[ -n "$VMID" ]]; then vm_passthrough "$VMID"; fi ;;
        reapply)     vm_reapply "$VMID" ;;
        revert)      if [[ -n "$VMID" ]]; then vm_revert "$VMID"; else host_revert; fi ;;
    esac
    finish_host_changes
    txn_commit
    log_ok "Done ($MODE)"
}

main "$@"
