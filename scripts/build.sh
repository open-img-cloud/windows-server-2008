#!/usr/bin/env bash
# Builds a Windows Server 2008 SP2 x64 cloud image (qcow2, BIOS) for
# OpenStack or Proxmox from YOUR Windows Server 2008 DVD, on Linux with
# QEMU/KVM and Packer.
#
# Usage:
#   scripts/build.sh --iso PATH --deps DIR [--edition EDITION]
#                    [--headless false] [--prepare-only] [-- extra packer args]
#
#   DIR: the packages listed in deps.sha256 (SP2, updates, virtio-win ISO,
#        Cloudbase-Init MSI), under their original file names. Each one is
#        checked against deps.sha256 before use.
#   EDITION: standard (default), enterprise, datacenter, or *-core
#   --prepare-only: assemble the setup CD and validate, no build (no KVM needed)
#
# Output: output/windows-server-2008-<edition>-bios/*.qcow2
set -euo pipefail

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

iso="" deps="" edition="standard" headless="true" prepare_only="false"
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) iso="$2"; shift 2 ;;
    --deps) deps="$2"; shift 2 ;;
    --edition) edition="$2"; shift 2 ;;
    --headless) headless="$2"; shift 2 ;;
    --prepare-only) prepare_only="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; extra=("$@"); break ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$iso" ] || [ -z "$deps" ]; then
  echo "--iso and --deps are required" >&2
  usage >&2
  exit 2
fi
[ -f "$iso" ] || { echo "ISO not found: $iso" >&2; exit 1; }
[ -d "$deps" ] || { echo "deps directory not found: $deps" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

qemu_binary="$(command -v qemu-system-x86_64 || true)"
if [ -z "$qemu_binary" ] && [ -x /usr/libexec/qemu-kvm ]; then
  qemu_binary=/usr/libexec/qemu-kvm
fi
missing=()
if [ "$prepare_only" = "false" ]; then
  [ -n "$qemu_binary" ] || missing+=(qemu-system-x86_64)
  command -v qemu-img >/dev/null || missing+=(qemu-img)
fi
for bin in packer xorriso sha256sum; do
  command -v "$bin" >/dev/null || missing+=("$bin")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "missing tools: ${missing[*]} (see README, Prerequisites)" >&2
  exit 1
fi
if [ "$prepare_only" = "false" ] && [ ! -w /dev/kvm ]; then
  echo "/dev/kvm is not writable: enable KVM and add your user to the kvm group" >&2
  exit 1
fi

# Every package must match deps.sha256 (lines "<sha256>  <vault key>").
echo "Checking the packages in $deps against deps.sha256"
while read -r sum key; do
  [ -n "$sum" ] || continue
  f="$deps/${key##*/}"
  [ -f "$f" ] || { echo "missing package: ${key##*/}" >&2; exit 1; }
  echo "$sum  $f" | sha256sum -c --quiet - || { echo "sha256 mismatch: ${key##*/}" >&2; exit 1; }
done < "$repo_root/deps.sha256"

pick() { # first file of $deps matching a glob
  local f
  for f in "$deps"/$1; do [ -f "$f" ] && { echo "$f"; return; }; done
  echo "no package matching $1 in $deps" >&2
  exit 1
}

# OIC_SETUP CD contents.
setup="$repo_root/build/setup"
rm -rf "$setup"
mkdir -p "$setup/updates" "$setup/msi" "$setup/drivers"
cp "$(pick 'windows6.0-kb948465-x64_*.exe')" "$setup/updates/sp2.exe"
for kb in kb968930 kb4493730 kb4474419 kb4534303 kb4536953; do
  cp "$(pick "windows6.0-$kb*-x64_*.msu")" "$setup/updates/$kb.msu"
done
cp "$(pick 'CloudbaseInitSetup_0_9_11_x64.msi')" "$setup/msi/"

# VirtIO: the Windows Server 2008 (2k8) drivers and the guest agent.
virtio="$(pick 'virtio-win-*.iso')"
for drv in viostor vioscsi NetKVM Balloon vioserial viorng pvpanic; do
  xorriso -osirrox on -indev "$virtio" -extract "/$drv/2k8/amd64" "$setup/drivers/$drv" 2>/dev/null
  # xorriso keeps the read-only modes of the ISO: make the copy writable.
  chmod -R u+w "$setup/drivers/$drv"
  rm -f "$setup/drivers/$drv"/*.pdb
done
# QEMU guest agent 101.2.0 (2019): the agent of virtio-win 0.1.221 imports
# TryAcquireSRWLockExclusive (Windows 7 and later) and does not start on 2008.
cp "$(pick 'qemu-ga-x86_64-101.2.0-1.el7ev.msi')" "$setup/msi/qemu-ga-x86_64.msi"
chmod -R u+w "$setup"
[ -f "$setup/drivers/viostor/viostor.inf" ] || { echo "no 2k8 viostor driver in $virtio" >&2; exit 1; }

# Red Hat signing certificate of the drivers: trusted in the guest before
# pnputil runs, otherwise Windows asks whether to trust the publisher and
# the setup task, which has no console, waits forever.
mkdir -p "$setup/oic"
openssl pkcs7 -inform DER -in "$setup/drivers/viostor/viostor.cat" -print_certs |
  awk '/^subject=.*Red Hat/{p=1} p{print} p&&/END CERTIFICATE/{exit}' > "$setup/oic/redhat.cer"
grep -q 'BEGIN CERTIFICATE' "$setup/oic/redhat.cer" || { echo "no Red Hat certificate in viostor.cat" >&2; exit 1; }

# In-guest scripts; cmd.exe wants CRLF line endings.
cp -r "$repo_root/setup/oic/." "$setup/oic/"
for f in "$setup"/oic/*.cmd "$setup"/oic/*.conf "$setup"/oic/*.xml; do sed -i 's/\r\{0,1\}$/\r/' "$f"; done

# Build only Administrator password: random, never stored in the repository.
# It is replaced at first boot by Cloudbase-Init (SetUserPasswordPlugin).
if [ -z "${PKR_VAR_build_password:-}" ]; then
  PKR_VAR_build_password="Oic-$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)-9a"
  export PKR_VAR_build_password
fi

iso_sum="$(sha256sum "$iso" | cut -d' ' -f1)"
cd "$repo_root/packer"
packer init .
packer validate -var "iso_path=$iso" -var "setup_dir=$setup" -var "edition=$edition" .
if [ "$prepare_only" = "true" ]; then
  echo "Setup CD ready in $setup (--prepare-only: no build)"
  exit 0
fi
PACKER_LOG="${PACKER_LOG:-0}" packer build \
  -var "iso_path=$iso" \
  -var "iso_checksum=sha256:$iso_sum" \
  -var "setup_dir=$setup" \
  -var "edition=$edition" \
  -var "headless=$headless" \
  -var "qemu_binary=$qemu_binary" \
  "${extra[@]}" .

out="$repo_root/output/windows-server-2008-$edition-bios"
echo
echo "Image ready: $out/windows-server-2008-$edition-bios.qcow2"
