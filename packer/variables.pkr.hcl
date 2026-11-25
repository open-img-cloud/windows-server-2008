# Inputs of the Windows Server 2008 build. scripts/build.sh sets most of
# them; they can also be passed with -var or a .pkrvars.hcl file.

variable "iso_path" {
  type        = string
  description = "Windows Server 2008 x64 DVD (build 6001, SP1 integrated)."
}

variable "iso_checksum" {
  type        = string
  default     = "none"
  description = "Checksum of the ISO (for example sha256:...). scripts/build.sh passes the sha256 it computed."
}

variable "setup_dir" {
  type        = string
  description = "Directory assembled by scripts/build.sh, burnt as the OIC_SETUP CD."
}

variable "edition" {
  type        = string
  default     = "standard"
  description = "standard, enterprise, datacenter, or one of them with -core."
  validation {
    condition     = contains(["standard", "enterprise", "datacenter", "standard-core", "enterprise-core", "datacenter-core"], var.edition)
    error_message = "The edition must be standard, enterprise, datacenter, standard-core, enterprise-core or datacenter-core."
  }
}

variable "image_index" {
  type        = number
  default     = 0
  description = "Index of the image inside sources/install.wim. 0 derives it from edition (1 standard, 2 enterprise, 3 datacenter, 4 to 6 the Core installations)."
}

variable "build_password" {
  type        = string
  sensitive   = true
  description = "Administrator password during the build only. Cloudbase-Init replaces it at first boot."
}

variable "ui_language" {
  type        = string
  default     = "en-US"
  description = "Setup and system language (the DVD must contain it)."
}

variable "time_zone" {
  type        = string
  default     = "UTC"
  description = "Windows time zone id."
}

variable "disk_size" {
  type        = string
  default     = "40G"
  description = "Build disk. Cloudbase-Init extends C: to the flavor disk at first boot."
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  type        = number
  default     = 4096
  description = "MiB."
}

variable "headless" {
  type        = bool
  default     = true
  description = "false shows the VM console (needs a display)."
}

variable "qemu_binary" {
  type    = string
  default = "qemu-system-x86_64"
}

variable "output_dir" {
  type        = string
  default     = ""
  description = "Where the image is written. Empty means output/ in the repository."
}

variable "qmp_socket" {
  type        = string
  default     = ""
  description = "Path of a QMP socket for the build VM (CI screenshots). Empty disables QMP."
}

variable "serial_log" {
  type        = string
  default     = ""
  description = "File receiving the first serial port of the build VM (progress of setup\\oic\\setup.cmd). Empty disables it."
}

variable "shutdown_timeout" {
  type        = string
  default     = "4h"
  description = "How long Packer waits for the VM to power itself off at the end of the in-guest setup."
}
