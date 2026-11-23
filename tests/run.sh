#!/usr/bin/env bash
# Offline tests for pve-intel-gpu.sh: a fake root (sysfs, /etc, realpc state) and
# stub commands (qm, update-grub, systemctl, apt-get, ...). Nothing on the real host
# is touched. Usage: bash tests/run.sh
# shellcheck disable=SC2015,SC2016
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../pve-intel-gpu.sh"
PASS=0; FAIL=0; T=""

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL [$T]: $*"; }
assert_eq()       { [[ "$1" == "$2" ]] && ok || bad "expected '$2', got '$1'${3:+ ($3)}"; }
assert_contains() { [[ "$1" == *"$2"* ]] && ok || bad "'$2' not found${3:+ ($3)}"; }
assert_not()      { [[ "$1" != *"$2"* ]] && ok || bad "'$2' unexpectedly found${3:+ ($3)}"; }
assert_file()     { [[ -e "$1" ]] && ok || bad "missing ${1#"$R"}"; }
assert_nofile()   { [[ ! -e "$1" ]] && ok || bad "unexpected ${1#"$R"}"; }

# ---------------------------------------------------------------- fake host
setup() {
    W="$(mktemp -d)"; R="$W/root"; B="$W/bin"; export FAKE="$W"
    mkdir -p "$R"/{proc,etc/default,etc/modprobe.d,etc/modules-load.d,usr/share/kvm,root/realpc} "$B" "$W/vms"
    local d="$R/sys/bus/pci/devices/0000:00:02.0"
    mkdir -p "$d" "$R/sys/bus/pci/drivers/i915" "$R/sys/bus/pci/devices/0000:00:1f.3"
    echo 0x8086 >"$d/vendor"; echo 0x030000 >"$d/class"; echo 0x4680 >"$d/device"
    ln -s ../../drivers/i915 "$d/driver"
    echo 'GRUB_DEFAULT=0' >"$R/etc/default/grub"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' >>"$R/etc/default/grub"
    echo 'BOOT_IMAGE=/boot/vmlinuz root=/dev/mapper/pve-root ro quiet' >"$R/proc/cmdline"
    : >"$W/calls"

    for c in update-grub update-initramfs proxmox-boot-tool systemctl; do
        printf '#!/bin/sh\necho "%s $*" >>"$FAKE/calls"\n' "$c" >"$B/$c"
    done
    printf '#!/bin/sh\necho "pve-manager/9.1.2/abc (running kernel: 6.17.2-1-pve)"\n' >"$B/pveversion"
    printf '#!/bin/sh\n[ "$3" = pve-qemu-kvm ] && echo "${QEMU_VER:-11.1.3-4}"\n' >"$B/dpkg-query"
    printf '#!/bin/sh\n[ "$1" = showhold ] && printf "pve-qemu-kvm\\npve-edk2-firmware-ovmf\\n"\nexit 0\n' >"$B/apt-mark"
    cat >"$B/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >>"$FAKE/calls"
if [ "$1" = -s ]; then
  echo "Inst i915-sriov-dkms (2025.1)"
  [ -n "$APT_SIM_BAD" ] && echo "Inst pve-qemu-kvm [11.1.3-4] (11.1.3-5 pve)"
fi
exit 0
EOF
    cat >"$B/qm" <<'EOF'
#!/usr/bin/env python3
import os, sys, re
d = os.path.join(os.environ["FAKE"], "vms")
a = sys.argv[1:]
def load(i):
    p = os.path.join(d, i + ".conf")
    if not os.path.exists(p): sys.exit(2)
    return p, open(p).read().split("\n")
def main_end(lines):
    for n, l in enumerate(lines):
        if l.startswith("["): return n
    return len(lines)
if a[0] == "list":
    print("      VMID NAME STATUS")
    for f in sorted(os.listdir(d)):
        if f.endswith(".conf"): print("       %s vm stopped" % f[:-5])
elif a[0] == "config":
    p, lines = load(a[1]); print("\n".join(l for l in lines[:main_end(lines)] if l))
elif a[0] == "status":
    print("status: " + ("running" if os.path.exists(os.path.join(d, a[1] + ".running")) else "stopped"))
elif a[0] == "set":
    p, lines = load(a[1]); rest = a[2:]
    with open(os.path.join(os.environ["FAKE"], "calls"), "a") as c: c.write("qm " + " ".join(a) + "\n")
    while rest:
        if rest[0] == "--delete": key, val = rest[1], None
        else: key, val = rest[0][2:], rest[1]
        if key == os.environ.get("QM_FAIL_KEY"): sys.stderr.write("simulated failure\n"); sys.exit(1)
        rest = rest[2:]
        e = main_end(lines); main = [l for l in lines[:e] if not l.startswith(key + ": ")]
        if val is not None: main.append(key + ": " + val)
        main = [l for l in main if l]
        lines = main + [""] + [l for l in lines[e:]]
    open(p, "w").write("\n".join(lines).strip("\n") + "\n")
EOF
    chmod +x "$B"/*
    export PATH="$B:$PATH" PIG_ROOT="$R" LOG_LEVEL=normal LOG_FILE="$W/tool.log"
    unset QM_FAIL_KEY APT_SIM_BAD QEMU_VER
}
teardown() { rm -rf "$W"; }

REALPC_ARGS='-acpitable file=/root/realpc/ssdt.aml -cpu host,hypervisor=off,pmu=on -smbios type=1,manufacturer="Maxsun",product="MS-Terminator B760M" -smbios type=4,manufacturer="Intel(R) Corporation",version="12th Gen Intel(R) Core(TM) i7-12700"'
mkvm() {   # id bios machine vga [args]
    { echo "bios: $2"; echo "machine: $3"; echo "vga: $4"; [[ -n "${5:-}" ]] && echo "args: $5"
      echo "sata0: local:100/vm-100-disk-1.raw,size=32G"; echo; echo "[snap1]"; echo "args: snapshot-args"; } >"$W/vms/$1.conf"
}
cfg() { "$B/qm" config "$1"; }
key() { cfg "$1" | sed -n "s/^$2: //p"; }
mkrom() { printf "\x55\xaa%s" "$1$RANDOM" >"$W/$1"; }
tool() { bash "$TOOL" "$@" 2>"$W/err"; }
hosttree() { (cd "$R" && find etc usr var -type f -exec sha256sum {} + 2>/dev/null | sort); }

# ---------------------------------------------------------------- tests
T="check-detects-generation"; setup
out="$(tool --mode status)"; rc=$?
assert_eq "$rc" 0
assert_contains "$out" "Alder Lake (12th gen)"
assert_contains "$out" "6-14-qemu10.rom"
assert_contains "$out" "QEMU >= 10"
teardown

T="arg-validation"; setup
tool --mode bogus; assert_eq "$?" 2
tool --mode check --vmid abc; assert_eq "$?" 2
tool --mode check --mode; assert_eq "$?" 2 "missing value"
tool --nonsense; assert_eq "$?" 2
teardown

T="prepare-idempotent"; setup
tool --mode prepare --yes; assert_eq "$?" 0
assert_contains "$(cat "$R/etc/default/grub")" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"'
assert_contains "$(cat "$R/etc/modules-load.d/pve-intel-gpu.conf")" vfio_pci
assert_contains "$(cat "$W/calls")" "update-grub"
assert_contains "$(cat "$W/calls")" "update-initramfs -u -k all"
: >"$W/calls"; tool --mode prepare --yes
assert_eq "$(cat "$W/calls")" "" "second run must not touch anything"
teardown

T="prepare-systemd-boot"; setup
mkdir -p "$R/etc/kernel"; echo "root=ZFS=rpool/ROOT/pve-1 boot=zfs" >"$R/etc/kernel/cmdline"
tool --mode prepare --yes
assert_eq "$(cat "$R/etc/kernel/cmdline")" "root=ZFS=rpool/ROOT/pve-1 boot=zfs intel_iommu=on iommu=pt"
assert_contains "$(cat "$W/calls")" "proxmox-boot-tool refresh"
teardown

T="dry-run-changes-nothing"; setup
mkvm 100 ovmf q35 vmware "$REALPC_ARGS"; mkrom r.rom
before="$(hosttree; cat "$W/vms/100.conf")"
tool --mode passthrough --vmid 100 --rom "$W/r.rom" --dry-run; assert_eq "$?" 0
assert_eq "$(hosttree; cat "$W/vms/100.conf")" "$before"
assert_contains "$(cat "$W/err")" "[dry-run]"
teardown

T="passthrough-keeps-realpc-args"; setup
mkvm 100 ovmf q35 vmware "$REALPC_ARGS"; mkrom r.rom
echo "INSTALL_MODE=strong" >"$R/root/realpc/.realpc-state"
tool --mode passthrough --vmid 100 --rom "$W/r.rom" --yes; assert_eq "$?" 0 "$(cat "$W/err")"
assert_eq "$(key 100 hostpci0)" "0000:00:02.0,romfile=r.rom"
assert_eq "$(key 100 vga)" "none"
a="$(key 100 args)"
assert_contains "$a" "$REALPC_ARGS" "realpc part kept verbatim"
assert_contains "$a" "-set device.hostpci0.bus=pcie.0 -set device.hostpci0.addr=02.0"
assert_contains "$a" "x-igd-gms=0x2"
assert_contains "$a" "x-igd-legacy-mode=on"
assert_contains "$(cat "$W/vms/100.conf")" "args: snapshot-args" "snapshot section untouched"
assert_contains "$(cat "$R/etc/modprobe.d/pve-intel-gpu.conf")" "ids=8086:4680"
assert_file "$R/usr/share/kvm/r.rom"
assert_eq "$(key 100 machine)" "q35" "machine not changed"
# second run is idempotent
: >"$W/calls"; tool --mode passthrough --vmid 100 --rom "$W/r.rom" --yes
assert_not "$(cat "$W/calls")" "qm set"
assert_eq "$(grep -o 'x-igd-gms' <<<"$(key 100 args)" | wc -l | tr -d ' ')" 1 "tokens not duplicated"
teardown

T="reapply-after-configvm"; setup
mkvm 100 ovmf q35 vmware "$REALPC_ARGS"; mkrom r.rom
tool --mode passthrough --vmid 100 --rom "$W/r.rom" --yes
"$B/qm" set 100 --args "$REALPC_ARGS" --vga vmware   # what realpc configvm does
out="$(tool --mode check)"
assert_contains "$out" "IGD args are missing"
assert_contains "$out" "expected none"
tool --mode reapply --vmid 100; assert_eq "$?" 0
assert_contains "$(key 100 args)" "x-igd-opregion=on"
assert_contains "$(key 100 args)" "$REALPC_ARGS"
assert_eq "$(key 100 vga)" none
teardown

T="vm-revert-restores-exactly"; setup
mkvm 100 ovmf q35 vmware "$REALPC_ARGS"; mkrom r.rom
orig="$(cat "$W/vms/100.conf")"
tool --mode passthrough --vmid 100 --rom "$W/r.rom" --audio --yes
assert_eq "$(key 100 hostpci1)" "0000:00:1f.3"
tool --mode revert --vmid 100 --yes; assert_eq "$?" 0
assert_eq "$(key 100 args)" "$REALPC_ARGS"
assert_eq "$(key 100 vga)" "vmware"
assert_eq "$(key 100 hostpci0)" ""
assert_eq "$(key 100 hostpci1)" ""
assert_eq "$(sort "$W/vms/100.conf")" "$(sort <<<"$orig")" "same set of lines"
teardown

T="vm-revert-vga-absent-args-absent"; setup
{ echo "bios: ovmf"; echo "machine: pc-i440fx-10.0"; } >"$W/vms/100.conf"; mkrom r.rom
tool --mode passthrough --vmid 100 --rom "$W/r.rom" --yes
assert_not "$(key 100 args)" "bus=pcie.0" "no pcie.0 on i440fx"
tool --mode revert --vmid 100 --yes
assert_eq "$(key 100 vga)" ""
assert_eq "$(key 100 args)" ""
teardown

T="host-revert"; setup
sed -i 's/"quiet"/"quiet intel_iommu=off"/' "$R/etc/default/grub"
mkvm 100 ovmf q35 vmware; mkrom r.rom
tool --mode passthrough --vmid 100 --rom "$W/r.rom" --yes
assert_contains "$(cat "$R/etc/default/grub")" '"quiet intel_iommu=on iommu=pt"' "replaced off->on"
tool --mode revert --yes; assert_eq "$?" 1 "refuses while a VM uses the iGPU"
tool --mode revert --vmid 100 --yes
tool --mode revert --yes; assert_eq "$?" 0 "$(cat "$W/err")"
assert_contains "$(cat "$R/etc/default/grub")" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=off"' "user value restored"
assert_nofile "$R/etc/modprobe.d/pve-intel-gpu.conf"
assert_nofile "$R/etc/modules-load.d/pve-intel-gpu.conf"
assert_nofile "$R/usr/share/kvm/r.rom"
teardown

T="foreign-rom-not-overwritten"; setup
mkvm 100 ovmf q35 vmware; mkrom r.rom; mkrom other.rom; cp "$W/other.rom" "$R/usr/share/kvm/r.rom"
tool --mode passthrough --vmid 100 --rom "$W/r.rom" --yes; assert_eq "$?" 1
assert_contains "$(cat "$W/err")" "not installed by this tool"
assert_eq "$(sha256sum <"$R/usr/share/kvm/r.rom")" "$(sha256sum <"$W/other.rom")"
teardown

T="rollback-on-failure"; setup
mkvm 100 ovmf q35 vmware "$REALPC_ARGS"; mkrom r.rom
before="$(hosttree)"; vmbefore="$(cat "$W/vms/100.conf")"
QM_FAIL_KEY=args tool --mode passthrough --vmid 100 --rom "$W/r.rom" --yes; rc=$?
assert_eq "$rc" 1
assert_contains "$(cat "$W/err")" "rolling back"
assert_eq "$(sort "$W/vms/100.conf")" "$(sort <<<"$vmbefore")" "VM config restored"
assert_eq "$(hosttree | grep -v 'var/lib/pve-intel-gpu')" "$(grep -v 'var/lib/pve-intel-gpu' <<<"$before")" "host files restored"
assert_eq "$(grep -o 'GRUB_CMDLINE.*' "$R/etc/default/grub")" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
assert_nofile "$R/usr/share/kvm/r.rom"
teardown

T="refuse-seabios-and-old-qemu"; setup
mkvm 100 seabios pc vga; mkrom r.rom
tool --mode passthrough --vmid 100 --rom "$W/r.rom" --yes; assert_eq "$?" 1
assert_contains "$(cat "$W/err")" "SeaBIOS"
mkvm 100 ovmf q35 vmware
QEMU_VER=9.2.0-5 tool --mode passthrough --vmid 100 --rom "$W/r.rom" --yes; assert_eq "$?" 1
assert_contains "$(cat "$W/err")" "QEMU >= 10"
teardown

T="vgpu-assigns-free-vfs"; setup
d="$R/sys/bus/pci/devices/0000:00:02.0"; echo 7 >"$d/sriov_totalvfs"; echo 0 >"$d/sriov_numvfs"
mkvm 101 ovmf q35 vmware "$REALPC_ARGS"; mkvm 102 ovmf pc-i440fx-10.0 std
tool --mode vgpu --vmid 101 --yes; assert_eq "$?" 0 "$(cat "$W/err")"
assert_eq "$(cat "$d/sriov_numvfs")" 7
assert_file "$R/etc/systemd/system/pve-intel-gpu-vfs.service"
assert_contains "$(cat "$W/calls")" "systemctl enable pve-intel-gpu-vfs.service"
assert_eq "$(key 101 hostpci0)" "0000:00:02.1,pcie=1"
assert_eq "$(key 101 args)" "$REALPC_ARGS" "args untouched by vgpu"
assert_eq "$(key 101 vga)" "vmware" "vga untouched by vgpu"
for i in 1 2 3 4 5 6 7; do mkdir -p "$R/sys/bus/pci/devices/0000:00:02.$i"; done
tool --mode vgpu --vmid 102 --yes
assert_eq "$(key 102 hostpci0)" "0000:00:02.2"
tool --mode passthrough --vmid 102 --yes; assert_eq "$?" 1 "VF still assigned -> no passthrough"
out="$(tool --mode check)"; assert_contains "$out" "VM 101: vGPU VF 0000:00:02.1"
tool --mode revert --vmid 101 --yes; tool --mode revert --vmid 102 --yes
assert_eq "$(key 101 hostpci0)" ""
tool --mode revert --yes; assert_eq "$?" 0 "$(cat "$W/err")"
assert_eq "$(cat "$d/sriov_numvfs")" 0
assert_nofile "$R/etc/systemd/system/pve-intel-gpu-vfs.service"
teardown

T="vgpu-without-sriov-needs-dkms"; setup
before="$(hosttree)"
tool --mode vgpu --yes; assert_eq "$?" 1
assert_contains "$(cat "$W/err")" "i915-sriov-dkms"
assert_eq "$(hosttree | grep -v 'var/lib/pve-intel-gpu')" "$(grep -v 'var/lib/pve-intel-gpu' <<<"$before")" "rolled back"
teardown

T="vgpu-dkms-install-respects-holds"; setup
echo fake >"$W/i915-sriov-dkms.deb"
APT_SIM_BAD=1 tool --mode vgpu --dkms-deb "$W/i915-sriov-dkms.deb" --yes; assert_eq "$?" 1
assert_contains "$(cat "$W/err")" "pve-qemu-kvm"
assert_not "$(cat "$W/calls")" "apt-get install -y"
tool --mode vgpu --dkms-deb "$W/i915-sriov-dkms.deb" --yes; assert_eq "$?" 0 "$(cat "$W/err")"
assert_contains "$(cat "$W/calls")" "apt-get install -y --no-upgrade"
assert_contains "$(cat "$R/etc/default/grub")" "i915.enable_guc=3 i915.max_vfs=7 module_blacklist=xe"
assert_contains "$(cat "$W/err")" "after a reboot"
teardown

T="smbios-mismatch-warning"; setup
echo 0x7d55 >"$R/sys/bus/pci/devices/0000:00:02.0/device"   # Meteor Lake
mkvm 100 ovmf q35 vmware "$REALPC_ARGS"; mkrom u.rom
tool --mode passthrough --vmid 100 --rom "$W/u.rom" --yes
out="$(tool --mode check)"
assert_contains "$out" "Core Ultra"
assert_contains "$out" "does not match the iGPU generation"
teardown

T="mode-switch-passthrough-to-vgpu"; setup
d="$R/sys/bus/pci/devices/0000:00:02.0"; echo 7 >"$d/sriov_totalvfs"; echo 0 >"$d/sriov_numvfs"
mkvm 100 ovmf q35 vmware; mkrom r.rom
tool --mode passthrough --yes
assert_file "$R/etc/modprobe.d/pve-intel-gpu.conf"
tool --mode vgpu --yes; assert_eq "$?" 0 "$(cat "$W/err")"
assert_nofile "$R/etc/modprobe.d/pve-intel-gpu.conf"
teardown

T="precheck-before-host-changes"; setup
mkvm 100 ovmf q35 vmware
before="$(hosttree)"
tool --mode passthrough --vmid 100 --yes; assert_eq "$?" 1
assert_contains "$(cat "$W/err")" "not found"
assert_not "$(cat "$W/err")" "rolling back" "nothing to roll back"
assert_eq "$(hosttree)" "$before"
teardown

echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" == 0 ]]
