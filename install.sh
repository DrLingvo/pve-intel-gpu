#!/usr/bin/env bash
# install.sh - install, update or remove pve-intel-gpu on a Proxmox VE host.
#
# Works together with realpc-clean-build (CONTRACT.md):
#   - takes the shared lock /run/lock/pve-host-tools.lock, so it never runs
#     while realpc-setup.sh or pve-intel-gpu.sh changes the host;
#   - installs only its own files (/opt/pve-intel-gpu, /usr/local/sbin link);
#     never touches packages, kernel parameters, modules or VM configs;
#   - every file is checked against the release SHA256SUMS before anything
#     is replaced; the old installation is restored if the swap fails;
#   - reports the host-tools contract version of realpc and of the new release.
# Host changes (IOMMU, vGPU, VMs) are made later by pve-intel-gpu itself.

set -Eeuo pipefail

REPO="DrLingvo/pve-intel-gpu"
ROOT="${PIG_INSTALL_ROOT:-}"                 # tests point this to a fake tree
PREFIX="$ROOT/opt/pve-intel-gpu"
BIN="$ROOT/usr/local/sbin/pve-intel-gpu"
LOCK="$ROOT/run/lock/pve-host-tools.lock"
TOOL_STATE="$ROOT/var/lib/pve-intel-gpu/state"
REALPC_STATE="$ROOT${REALPC_DIR:-/root/realpc}/.realpc-state"

MODE=install; RELEASE=latest; FROM=""; YES=0; FORCE=0

usage() {
    cat <<EOF
Usage: install.sh [--mode install|update|uninstall|check] [options]

  install    Download a release, verify SHA256SUMS, install to ${PREFIX#"$ROOT"}
  update     Same as install over an existing installation (log is kept)
  uninstall  Remove the installed files (refused while host changes are active)
  check      Show what is installed and the host-tools contract status

Options:
  --release TAG|latest   Release to install (default: latest)
  --from DIR             Install from a local checkout or a directory with
                         downloaded release files instead of downloading
  --yes                  Do not ask for confirmation
  --force                uninstall: remove files even with active host changes
  -h, --help             This help

Quick start on the Proxmox host:
  curl -fsSLO https://github.com/$REPO/releases/latest/download/install.sh
  bash install.sh --yes
  pve-intel-gpu --mode status
EOF
}

say()  { printf '[%s] %s\n' "$1" "$2" >&2; }
info() { say INFO "$*"; }
ok()   { say OK "$*"; }
warn() { say WARN "$*"; }
die()  { say ERROR "$*"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)    MODE="${2-}"; shift 2 || die "--mode needs a value" ;;
        --release) RELEASE="${2-}"; shift 2 || die "--release needs a value" ;;
        --from)    FROM="${2-}"; shift 2 || die "--from needs a value" ;;
        --yes|-y)  YES=1; shift ;;
        --force)   FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
done
case "$MODE" in install|update|uninstall|check) ;; *) echo "Unknown mode: $MODE" >&2; exit 2 ;; esac
[[ "$RELEASE" =~ ^(latest|v[0-9A-Za-z._-]+)$ ]] || { echo "--release must be latest or a tag like v0.3.0" >&2; exit 2; }

confirm() {
    [[ "$YES" == 1 ]] && return 0
    [[ -t 0 ]] || die "Not interactive: add --yes"
    local a; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y || "$a" == yes ]]
}

need_root() { [[ -n "$ROOT" || "$(id -u)" == 0 ]] || die "Run as root"; }

take_lock() {
    command -v flock >/dev/null || die "flock is required"
    mkdir -p "$(dirname "$LOCK")"
    exec {LOCK_FD}>"$LOCK"
    flock -w "${PIG_LOCK_TIMEOUT:-60}" "$LOCK_FD" \
        || die "Another host tool holds $LOCK (realpc-setup.sh or pve-intel-gpu running). Try again later."
}

kv() { [[ -f "$2" ]] && sed -n "s/^$1=//p" "$2" | tail -n1; return 0; }
script_var() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$2" | head -n1; }

contract_report() {   # $1 = contract version of the installed/new tool
    local ours=$1 rp
    rp="$(kv CONTRACT_VERSION "$REALPC_STATE")"
    if [[ ! -f "$REALPC_STATE" ]]; then info "realpc-clean-build: not installed"
    elif [[ "$rp" == "$ours" ]]; then ok "realpc-clean-build: host-tools contract v$rp matches"
    elif [[ -z "$rp" ]]; then warn "realpc-clean-build without the host-tools contract: after its configvm run 'pve-intel-gpu --mode reapply --vmid N'"
    else warn "Contract mismatch: realpc v$rp, pve-intel-gpu v$ours. Update the older tool before changing VMs."; fi
}

# ---------------------------------------------------------------- fetch + verify
STAGE=""
cleanup() { [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf "$STAGE"; return 0; }
trap cleanup EXIT

dl() {   # URL FILE
    curl -fsSL --retry 3 -o "$2" "$1" || die "Download failed: $1"
}

# Stage layout: pve-intel-gpu.sh install.sh CONTRACT.md bios/{*.rom,catalog.tsv,SHA256SUMS} SOURCE
stage_release() {
    local base f
    command -v curl >/dev/null || die "curl is required"
    if [[ "$RELEASE" == latest ]]; then base="https://github.com/$REPO/releases/latest/download"
    else base="https://github.com/$REPO/releases/download/$RELEASE"; fi
    mkdir -p "$STAGE/dl"
    dl "$base/SHA256SUMS" "$STAGE/dl/SHA256SUMS"
    while read -r _ f; do
        f="${f#./}"; f="${f#\*}"
        [[ "$f" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Unexpected file name in SHA256SUMS: $f"
        dl "$base/$f" "$STAGE/dl/$f"
    done <"$STAGE/dl/SHA256SUMS"
    (cd "$STAGE/dl" && sha256sum -c --quiet SHA256SUMS >&2) || die "Release files do not match SHA256SUMS; nothing installed"
    ok "Release files verified against SHA256SUMS"
    arrange_release "$STAGE/dl" "release $RELEASE"
}

arrange_release() {   # DIR SOURCE  (flat release layout)
    local d=$1
    mkdir -p "$STAGE/new/bios"
    cp "$d/pve-intel-gpu.sh" "$d/CONTRACT.md" "$STAGE/new/"
    [[ -f "$d/install.sh" ]] && cp "$d/install.sh" "$STAGE/new/"
    cp "$d"/*.rom "$d/catalog.tsv" "$STAGE/new/bios/"
    cp "$d/bios-SHA256SUMS" "$STAGE/new/bios/SHA256SUMS"
    echo "$2" >"$STAGE/new/SOURCE"
}

stage_from_dir() {
    local d=$FROM
    [[ -d "$d" ]] || die "No such directory: $d"
    if [[ -f "$d/bios-SHA256SUMS" ]]; then          # downloaded release files
        [[ -f "$d/SHA256SUMS" ]] || die "$d has release files but no SHA256SUMS"
        (cd "$d" && sha256sum -c --quiet SHA256SUMS >&2) || die "Files in $d do not match SHA256SUMS; nothing installed"
        arrange_release "$d" "files in $(cd "$d" && pwd)"
    else                                            # repository checkout
        [[ -f "$d/pve-intel-gpu.sh" && -d "$d/bios" ]] || die "$d is neither a checkout nor a release directory"
        mkdir -p "$STAGE/new/bios"
        cp "$d/pve-intel-gpu.sh" "$d/CONTRACT.md" "$STAGE/new/"
        [[ -f "$d/install.sh" ]] && cp "$d/install.sh" "$STAGE/new/"
        cp "$d"/bios/*.rom "$d/bios/catalog.tsv" "$d/bios/SHA256SUMS" "$STAGE/new/bios/"
        local rev=""; rev="$(git -C "$d" rev-parse --short HEAD 2>/dev/null || true)"
        echo "checkout $(cd "$d" && pwd)${rev:+ @$rev}" >"$STAGE/new/SOURCE"
    fi
}

verify_stage() {
    local n=$STAGE/new
    bash -n "$n/pve-intel-gpu.sh" || die "pve-intel-gpu.sh has syntax errors"
    (cd "$n/bios" && sha256sum -c --quiet SHA256SUMS >&2) || die "bios/ files do not match bios/SHA256SUMS; nothing installed"
    local v; v="$(script_var VERSION "$n/pve-intel-gpu.sh")"
    [[ -n "$v" ]] || die "Cannot read VERSION from pve-intel-gpu.sh"
    echo "$v" >"$n/VERSION"
    chmod 755 "$n/pve-intel-gpu.sh"; [[ -f "$n/install.sh" ]] && chmod 755 "$n/install.sh"
    return 0
}

# ---------------------------------------------------------------- modes
mode_install() {
    need_root
    local old_v=""
    [[ -f "$PREFIX/VERSION" ]] && old_v="$(cat "$PREFIX/VERSION")"
    if [[ "$MODE" == update && -z "$old_v" ]]; then die "Nothing to update: ${PREFIX#"$ROOT"} is not installed"; fi
    take_lock
    STAGE="$(mktemp -d)"
    if [[ -n "$FROM" ]]; then stage_from_dir; else stage_release; fi
    verify_stage
    local new_v new_c; new_v="$(cat "$STAGE/new/VERSION")"
    new_c="$(script_var CONTRACT_VERSION "$STAGE/new/pve-intel-gpu.sh")"
    info "pve-intel-gpu ${old_v:+$old_v -> }$new_v ($(cat "$STAGE/new/SOURCE"))"
    contract_report "$new_c"
    local tc; tc="$(kv CONTRACT_VERSION "$TOOL_STATE")"
    [[ -z "$tc" || "$tc" == "$new_c" ]] || warn "Host changes were made with contract v$tc, the new release uses v$new_c"
    confirm "Install pve-intel-gpu $new_v to ${PREFIX#"$ROOT"}?" || { info "Canceled"; exit 0; }

    # keep the log of the old installation
    [[ -f "$PREFIX/pve-intel-gpu.log" ]] && cp -p "$PREFIX/pve-intel-gpu.log" "$STAGE/new/"
    mkdir -p "$(dirname "$PREFIX")" "$(dirname "$BIN")"
    local old="$PREFIX.old.$$"
    if [[ -e "$PREFIX" ]]; then mv "$PREFIX" "$old" || die "Cannot move the old installation aside"; fi
    if ! mv "$STAGE/new" "$PREFIX" || ! ln -sfn "$PREFIX/pve-intel-gpu.sh" "$BIN"; then
        rm -rf "$PREFIX"; [[ -e "$old" ]] && mv "$old" "$PREFIX"
        die "Install failed; the previous installation was restored"
    fi
    rm -rf "$old"
    ok "Installed pve-intel-gpu $new_v: ${PREFIX#"$ROOT"} (command: ${BIN#"$ROOT"})"
    info "Next: pve-intel-gpu --mode status"
    info "      pve-intel-gpu --mode vgpu --vmid N --guest android   (GVT-g on Gen8-9, SR-IOV on Gen12+)"
}

mode_uninstall() {
    need_root
    [[ -d "$PREFIX" ]] || { info "Not installed"; return 0; }
    take_lock
    local hm vms=""
    hm="$(kv HOST_MODE "$TOOL_STATE")"
    [[ -d "$ROOT/var/lib/pve-intel-gpu/vm" ]] && vms="$(find "$ROOT/var/lib/pve-intel-gpu/vm" -mindepth 2 -maxdepth 2 -name hostpci -printf '%h\n' 2>/dev/null | xargs -r -n1 basename | xargs)"
    if [[ -n "$hm" || -n "$vms" ]] && [[ "$FORCE" != 1 ]]; then
        die "Host changes are still active (host mode: ${hm:-none}; VMs: ${vms:-none}). Run 'pve-intel-gpu --mode revert --vmid N' for each VM and 'pve-intel-gpu --mode revert', or use --force to keep them and only remove the files."
    fi
    confirm "Remove ${PREFIX#"$ROOT"} and ${BIN#"$ROOT"}?" || { info "Canceled"; exit 0; }
    if [[ -L "$BIN" && "$(readlink "$BIN")" == "$PREFIX/"* ]]; then rm -f "$BIN"; fi
    rm -rf "$PREFIX"
    [[ -n "$hm" || -n "$vms" ]] && warn "Host changes were kept (--force); state stays in /var/lib/pve-intel-gpu"
    ok "pve-intel-gpu removed"
}

mode_check() {
    if [[ -f "$PREFIX/VERSION" ]]; then
        ok "Installed: pve-intel-gpu $(cat "$PREFIX/VERSION") ($(cat "$PREFIX/SOURCE" 2>/dev/null || echo unknown source))"
        if [[ -L "$BIN" ]]; then ok "Command: ${BIN#"$ROOT"}"; else warn "Command link ${BIN#"$ROOT"} is missing"; fi
        if (cd "$PREFIX/bios" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); then ok "bios/ checksums OK"
        else warn "bios/ checksums do NOT match"; fi
        contract_report "$(script_var CONTRACT_VERSION "$PREFIX/pve-intel-gpu.sh")"
    else
        info "pve-intel-gpu is not installed in ${PREFIX#"$ROOT"}"
        contract_report 1
    fi
    info "Host mode: $(kv HOST_MODE "$TOOL_STATE" | grep . || echo none)"
}

case "$MODE" in
    install|update) mode_install ;;
    uninstall)      mode_uninstall ;;
    check)          mode_check ;;
esac
