#!/usr/bin/env bash
# Stage the release files into OUTDIR (flat layout) with one SHA256SUMS.
# Used by .github/workflows/release.yml and by tests/run.sh, so the installer
# is tested against exactly what a release contains.
set -euo pipefail
out=${1:?usage: stage-release.sh OUTDIR}
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$out"
cp "$here/pve-intel-gpu.sh" "$here/install.sh" "$here/CONTRACT.md" "$here"/bios/*.rom "$here/bios/catalog.tsv" "$out/"
cp "$here/bios/SHA256SUMS" "$out/bios-SHA256SUMS"
sed -n 's/^CONTRACT_VERSION=//p' "$here/pve-intel-gpu.sh" >"$out/CONTRACT_VERSION"
( cd "$out" && rm -f SHA256SUMS && sha256sum ./* > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS )
