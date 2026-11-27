# Windows Server 2008 SP2: build your own cloud image

<p>
  <a href="https://github.com/open-img-cloud/windows-server-2008/actions/workflows/lint.yml"><img alt="Lint" src="https://github.com/open-img-cloud/windows-server-2008/actions/workflows/lint.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-GPL--2.0-blue"></a>
</p>

> **Build your own: no published image.** This repository holds the tooling
> to build a Windows Server 2008 SP2 x64 cloud image for **OpenStack** or
> **Proxmox VE** from **your own** Windows Server 2008 DVD, on a Linux host
> with KVM. openimages.cloud does not distribute Windows images.

> **Security warning.** Windows Server 2008 reached the end of its extended
> support in January 2020. The image built here carries every public update
> up to that date, nothing after it (later fixes were paid Extended Security
> Updates). Use it only for legacy workloads, isolated from the Internet.

## What you get

One compressed, sysprepped `qcow2` per build:

- Windows Server 2008 **SP2** x64, Standard, Enterprise or Datacenter (full
  installation or Server Core);
- patched to **January 2020**: servicing stack (KB4493730), SHA-2 code
  signing support (KB4474419), the January 2020 monthly rollup (KB4534303),
  then the January 2020 servicing stack (KB4536953);
- PowerShell 2.0 and WinRM 2.0 (KB968930);
- VirtIO drivers for 2008 (storage virtio-blk and virtio-scsi, network,
  balloon, serial, RNG, pvpanic) and the QEMU guest agent (without VSS);
- Cloudbase-Init 0.9.11: hostname, Administrator password, SSH keys and
  user data from the config drive or the metadata service, C: extended to
  the disk size;
- Remote Desktop and ping allowed, no hibernation, high performance power
  plan;
- **BIOS** only: Windows Server 2008 does not boot under UEFI (OVMF).

## Licensing and activation

Licensing is the operator's job; the kit does not change it.

- The Windows Server 2008 DVD used by the CI (build 6001) refuses an
  empty product key. The kit installs the edition with its public KMS
  client setup key (GVLK, [published by Microsoft][gvlk]): Windows is
  installed **unactivated**, with the usual grace period. A GVLK is not a
  licence. The DVD terms do not grant a right to redistribute it
  ([Microsoft license terms][ms-useterms]). Do not publish images built
  from it.
- With your own licence: enter your product key after the first boot
  (`slmgr -ipk <key>`, then `slmgr -ato`), or point the instance to your KMS
  server.

## How the build works

Windows Server 2008 has no PowerShell by default and only WinRM 1.1, so
Packer does not connect to the VM (`communicator = "none"`). Everything runs
inside the guest, from a second CD (`OIC_SETUP`) assembled by
`scripts/build.sh`:

1. Windows Setup with `autounattend.xml` (VirtIO storage driver loaded in
   WinPE, every VirtIO driver staged into the system).
2. First logon: `setup\oic\start.cmd` registers `setup\oic\setup.cmd` as a
   startup task running as SYSTEM.
3. `setup.cmd` installs one package per boot: SP2, KB968930, KB4493730,
   KB4474419, KB4534303, KB4536953, then the QEMU guest agent and
   Cloudbase-Init, applies the image settings, cleans up and runs
   `sysprep /generalize /oobe /shutdown`.
4. Packer waits for the VM to power off and compresses the disk.

Progress goes to the first serial port (`-var serial_log=...`), one line per
step; the last line is `OIC-SETUP-DONE`, or `OIC-SETUP-FAILED` followed by a
power off. No network access is needed during the build.

## Prerequisites

Linux x86_64 with KVM (`/dev/kvm` writable), `qemu-system-x86_64`,
`qemu-img`, `xorriso`, `sha256sum`, [Packer][packer] 1.10 or later. About
3 to 4 hours on 2 vCPUs, 4 GiB of RAM, 50 GB of disk.

## Inputs

- **The DVD**: `6001.18000.080118-1840_amd64fre_Server_en-us-KRMSXFRE_EN_DVD.iso`
  (Windows Server 2008 with SP1 integrated, x64, sha256 in `iso.sha256`).
  Other build 6001 x64 DVDs work if their `install.wim` has the same layout:

  | Index | Edition | `--edition` |
  |---|---|---|
  | 1 | Standard | `standard` |
  | 2 | Enterprise | `enterprise` |
  | 3 | Datacenter | `datacenter` |
  | 4 | Standard (Server Core) | `standard-core` |
  | 5 | Enterprise (Server Core) | `enterprise-core` |
  | 6 | Datacenter (Server Core) | `datacenter-core` |

- **The packages** listed in `deps.sha256`, in one directory, under their
  original names. `scripts/build.sh` checks each one against its sha256.

  | Package | Source |
  |---|---|
  | SP2 (KB948465) and the five updates (`windows6.0-kb*.exe/.msu`) | [Microsoft Update Catalog][catalog] (the SHA-1 is part of each file name) |
  | `virtio-win-0.1.221.iso` | [virtio-win archive][virtio]: its `2k8` drivers are used |
  | `qemu-ga-x64-100.0.0.0-3.el7ev.msi` | [QEMU guest agent archive][qga] (`qemu-ga-x64.msi` of 100.0.0, renamed): later agents import Windows 7 functions (`CM_Get_DevNode_PropertyW` of cfgmgr32 from 101, `TryAcquireSRWLockExclusive` from 102) that Windows Server 2008 lacks. The MSI is not signed, the pinned sha256 is the check |
  | `CloudbaseInitSetup_0_9_11_x64.msi` | [Cloudbase-Init 0.9.11][cbi]: the last release whose embedded Python (3.4) runs on 2008 |

- **Two root certificates**, in `setup/oic/`, from the Microsoft root
  distribution (`ctldl.windowsupdate.com/.../trustedr/en/<sha1>.crt`):
  VeriSign Class 3 Public Primary CA - G5
  (`4eb6d578499b1ccf5f581ead56be3d9b6744a5e5`) and Thawte Timestamping CA
  (`be36a4562fb2ee05dbb3d32323adf445084ed656`). The VirtIO drivers chain to
  them, and a Windows Server 2008 without Internet access does not have them:
  without them it sees the packages as unsigned (`0x800b010a`). The public
  key of the G5 root is the one of the cross certificate in the catalogs.

## Build

```sh
git clone https://github.com/open-img-cloud/windows-server-2008.git
cd windows-server-2008

# Windows Server 2008 SP2 Standard
scripts/build.sh --iso ~/iso/6001.18000.080118-1840_amd64fre_Server_en-us-KRMSXFRE_EN_DVD.iso \
  --deps ~/iso/deps-2008

# Datacenter, with the in-guest log in serial.log
scripts/build.sh --iso ~/iso/ws2008.iso --deps ~/iso/deps-2008 --edition datacenter \
  -- -var serial_log=$PWD/serial.log

# Assemble the setup CD and validate only (no KVM needed)
scripts/build.sh --iso ~/iso/ws2008.iso --deps ~/iso/deps-2008 --prepare-only
```

Boot test of the result: guest agent, hostname and password through an
OpenStack metadata server (`scripts/metadata-server.py`, reached by an
iptables redirect, so sudo is needed), the posted password decrypted with
the instance key and checked by a logon in the guest, C: extended to a
60 GB disk:

```sh
scripts/smoke.sh output/windows-server-2008-standard-bios/windows-server-2008-standard-bios.qcow2
```

## Upload to OpenStack Glance

```sh
openstack image create "Windows Server 2008 SP2 Standard" \
  --disk-format qcow2 --container-format bare \
  --file output/windows-server-2008-standard-bios/windows-server-2008-standard-bios.qcow2 \
  --property os_type=windows --property os_distro=windows --property os_version=2008 \
  --property hw_firmware_type=bios --property hw_disk_bus=virtio \
  --property hw_qemu_guest_agent=yes --property hw_vif_model=virtio \
  --min-disk 40 --min-ram 2048
```

The flavor disk must be at least 40 GB. Get the Administrator password with
`nova get-password <server> <private key>` (the key pair must be RSA), or
pass one with the `admin_pass` metadata. Cloudbase-Init reads the metadata
API before a config drive: only that API can receive the generated
password. Without a metadata API, the first boot waits about a minute and a
half before it reads the config drive.

## Import into Proxmox VE

```sh
qm create 9008 --name ws2008-template --memory 4096 --cores 2 --ostype w2k8 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 --agent enabled=1
qm set 9008 --virtio0 local-lvm:0,import-from=/path/windows-server-2008-standard-bios.qcow2
qm set 9008 --ide2 local-lvm:cloudinit --boot order=virtio0
qm set 9008 --citype configdrive2 --ciuser Administrator --cipassword '<password>'
qm template 9008
```

## Known limits

- **Network configuration**: Cloudbase-Init 0.9.11 does not apply static
  network settings from the metadata on Windows; the image relies on DHCP
  (the OpenStack and Proxmox default).
- **No UEFI**: Windows Server 2008 (non R2) does not boot under OVMF.
- **No VSS freeze**: the guest agent is installed without its VSS
  provider, whose registration fails on 2008. `guest-fsfreeze-freeze` is
  not available, so snapshots of a running instance are crash consistent
  only.
- **No WinRM listener from Cloudbase-Init**: its WinRM plugins fail on
  2008 (access denied) and are left out; Remote Desktop is the remote
  access. Its licensing plugin is left out too: activation is done by the
  operator (`slmgr /skms <host>` then `slmgr /ato`).
- **No updates after January 2020**: Windows Update may no longer offer
  anything for this release.

## Validation and CI

`.github/workflows/lint.yml` runs on every pull request: `packer fmt`,
`packer validate` for every edition, rendering of `autounattend.xml`
checked by `xmllint`, `xmllint` on the sysprep answer file, Cloudbase-Init
configuration syntax, `bash -n` and `shellcheck`, Python syntax, the format
of the pinned files, and a check that no em dash slipped in.

`.github/workflows/build.yml` is a manual build on a GitHub-hosted runner
with KVM. It fetches the DVD and the packages pinned in `iso.sha256` and
`deps.sha256` from the project's private ISO vault, builds, checks the
in-guest log, boots the image once (`scripts/smoke.sh`), and stores the
image in that private vault. The image is never a workflow artifact, and
never published.

## Repository layout

```
packer/
  windows.pkr.hcl            source and build (communicator none)
  variables.pkr.hcl          inputs, documented
  autounattend.xml.pkrtpl    Windows Setup answer file (Vista schema)
  virtio-serial.cfg          guest agent channel of the build VM (-readconfig)
setup/oic/
  start.cmd                  first logon: registers the setup task
  setup.cmd                  in-guest build, one stage per boot
  Unattend.xml               sysprep answer file
  cloudbase-init*.conf       Cloudbase-Init 0.9.11 configuration
  *-root.cer                 roots of the driver signatures (see below)
scripts/
  build.sh                   Linux entry point (assembles the setup CD)
  smoke.sh                   boot test of a built image (guest agent)
  ci/                        CI helpers (vault, screenshots)
iso.sha256, deps.sha256      pinned inputs (sha256 and path in the vault)
```

## License

GPL-2.0 for the tooling in this repository. Windows, the updates, the
VirtIO drivers and Cloudbase-Init keep their own licenses.

[gvlk]: https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys#windows-server-2008
[ms-useterms]: https://www.microsoft.com/en-us/useterms
[catalog]: https://www.catalog.update.microsoft.com/
[virtio]: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/
[qga]: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-qemu-ga/qemu-ga-win-100.0.0.0-3.el7ev/
[cbi]: https://github.com/cloudbase/cloudbase-init/releases/tag/0.9.11
[packer]: https://developer.hashicorp.com/packer
