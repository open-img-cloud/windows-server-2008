# Windows Server 2008 (SP2, patched to January 2020) cloud image for
# OpenStack and Proxmox, built on Linux with QEMU/KVM.
#
# Windows Server 2008 has no PowerShell by default and only WinRM 1.1, so
# Packer does not talk to the VM at all (communicator "none"). Everything
# runs inside the guest from the OIC_SETUP CD:
#   Windows Setup (autounattend.xml.pkrtpl, VirtIO drivers staged from the
#   CD) -> first logon registers setup\oic\setup.cmd as a startup task ->
#   SP2 -> servicing stack, SHA-2 support, January 2020 rollup, servicing
#   stack (one reboot each) -> PowerShell 2.0 -> QEMU guest agent and
#   Cloudbase-Init -> cleanup -> sysprep /generalize /oobe /shutdown.
# Packer waits for the VM to power off, then compresses the disk.
# Progress is written to the first serial port (serial_log).
#
# Entry point: scripts/build.sh (it assembles the setup CD).

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.8"
    }
  }
}

locals {
  # install.wim layout of the Windows Server 2008 x64 DVD (build 6001).
  edition_index = {
    "standard"        = 1
    "enterprise"      = 2
    "datacenter"      = 3
    "standard-core"   = 4
    "enterprise-core" = 5
    "datacenter-core" = 6
  }
  image_index = var.image_index > 0 ? var.image_index : local.edition_index[var.edition]

  vm_name    = "windows-server-2008-${var.edition}-bios"
  output_dir = var.output_dir != "" ? var.output_dir : "${path.root}/../output"

  # The password lands in an XML file: escape the XML special characters.
  xml_password = replace(replace(replace(var.build_password, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")

  autounattend = templatefile("${path.root}/autounattend.xml.pkrtpl", {
    image_index    = local.image_index
    admin_password = local.xml_password
    ui_language    = var.ui_language
    time_zone      = var.time_zone
  })

  serial_args = var.serial_log != "" ? [["-serial", "file:${var.serial_log}"]] : []
}

source "qemu" "windows" {
  vm_name          = "${local.vm_name}.qcow2"
  output_directory = "${local.output_dir}/${local.vm_name}"

  iso_url      = var.iso_path
  iso_checksum = var.iso_checksum

  qemu_binary = var.qemu_binary
  accelerator = "kvm"
  cpu_model   = "host"
  cpus        = var.cpus
  memory      = var.memory
  headless    = var.headless

  # Optional QMP socket, used by the CI to take screenshots of the console.
  qmp_enable      = var.qmp_socket != ""
  qmp_socket_path = var.qmp_socket != "" ? var.qmp_socket : null

  # BIOS only: Windows Server 2008 does not boot under OVMF (UEFI).
  machine_type = "pc"

  disk_size          = var.disk_size
  disk_interface     = "virtio"
  format             = "qcow2"
  disk_discard       = "unmap"
  disk_detect_zeroes = "unmap"
  disk_compression   = true
  net_device         = "virtio-net"
  cdrom_interface    = "ide"

  # Second CD, assembled by scripts/build.sh: VirtIO drivers, SP2, updates,
  # QEMU guest agent, Cloudbase-Init and the oic\ scripts.
  cd_label = "OIC_SETUP"
  cd_files = ["${abspath(var.setup_dir)}/*"]
  cd_content = {
    "autounattend.xml" = local.autounattend
  }

  boot_wait = "5s"
  qemuargs  = local.serial_args

  # No connection to the guest: the build ends when the VM powers itself off
  # after sysprep. SP2 and the January 2020 rollup take most of the time.
  communicator     = "none"
  shutdown_timeout = var.shutdown_timeout
}

build {
  name    = "windows-server"
  sources = ["source.qemu.windows"]

  post-processor "checksum" {
    checksum_types = ["sha256"]
    output         = "${local.output_dir}/${local.vm_name}/${local.vm_name}.qcow2.{{.ChecksumType}}"
  }
}
