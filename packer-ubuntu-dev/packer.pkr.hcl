packer {
  required_plugins {
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = "~> 1"
    }
  }
}


locals {
  # Packer serves files via its built-in http server AND can also mount a "cidata" ISO.
  # For Ubuntu autoinstall, mounting "cidata" (NoCloud) is usually the most reliable.
  cidata_label = "cidata"
}

source "hyperv-iso" "ubuntu" {
  vm_name              = var.vm_name
  generation           = 2
  switch_name          = var.switch_name

  iso_url              = "file:///${var.iso_path}"
  iso_checksum         = "none" # set to sha256:... once you decide and pin the ISO

  cpus                 = var.cpus
  memory               = var.memory_mb
  disk_size            = var.disk_size_mb

  enable_secure_boot   = false

  communicator         = "ssh"
  ssh_username         = var.ssh_username
  ssh_private_key_file = var.packer_private_key_path
  ssh_timeout          = "30m"

  # Provide NoCloud autoinstall config via attached ISO
  cd_files             = ["http/user-data", "http/meta-data"]
  cd_label             = local.cidata_label

  shutdown_command     = "sudo shutdown -P now"

  # Boot command: tell the live-server installer to use autoinstall + NoCloud from cidata
  boot_command = [
    "<esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz autoinstall ds=nocloud ---<enter>",
    "initrd /casper/initrd<enter>",
    "boot<enter>"
  ]

}

build {
  name    = "ubuntu-dev-hyperv"
  sources = ["source.hyperv-iso.ubuntu"]

  provisioner "shell" {
    scripts = [
      "scripts/00-base.sh",
      "scripts/10-ssh-hardening.sh",
      "scripts/20-firewall-fail2ban.sh",
      "scripts/30-unattended-upgrades.sh",
      "scripts/40-sysctl.sh",
      "scripts/50-docker.sh",
      "scripts/60-remove-key.sh",
      "scripts/70-check-cloud-init.sh"
    ]
  }

  post-processor "shell-local" {
    inline = [
      "powershell -NoProfile -Command \"Write-Host 'Build complete. Artifact in ${var.output_dir}.'\""
    ]
  }
}
