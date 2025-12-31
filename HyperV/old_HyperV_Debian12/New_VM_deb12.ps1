<#
Creates a new Hyper-V VM from a pre-built "golden" Debian 12 base VHDX, using a differencing disk
and a per-VM cloud-init NoCloud seed ISO (user-data/meta-data/network-config).

Prereqs:
- Hyper-V enabled
- WSL installed with genisoimage available:
    wsl.exe -e bash -lc "command -v genisoimage || sudo apt update && sudo apt install -y genisoimage"
- Base image exists at $BaseVhdxPath (read-only recommended)

Notes:
- This script assumes the Debian cloud image already contains cloud-init (it does).
- This script assumes your base image has what you want baked in (optional):
    - openssh-server enabled
    - hyperv-daemons enabled (hv-kvp-daemon) for IP reporting
  Even if not baked in, this script installs/enables key items via cloud-init.
#>

# -----------------------------
# User config (edit these)
# -----------------------------
$VmName        = "jumpbox"
$SwitchName    = "VirtualSwitch1"
$CpuCount      = 3
$MemStartup    = 4GB

# Static IP for this VM (since you're using network-config)
$IpAddress     = "192.168.137.21"
$CidrPrefix    = 24
$Gateway       = "192.168.137.1"
$DnsServers    = @("1.1.1.1","8.8.8.8")

# Where your golden base VHDX lives
$BaseVhdxPath  = "C:\Images\Golden\debian12-base.vhdx"

# Where to create the VM files
$VmRootDir     = "C:\Images\Current\kube\$VmName"

# Your SSH public key
$PubKeyPath    = "$env:USERPROFILE\.ssh\id_ed25519.pub"

# -----------------------------
# Safety checks
# -----------------------------
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    throw "VM '$VmName' already exists. Aborting."
}
if (-not (Test-Path $BaseVhdxPath)) {
    throw "Base VHDX not found: $BaseVhdxPath"
}
if (-not (Test-Path $PubKeyPath)) {
    throw "SSH public key not found: $PubKeyPath"
}

$pubKey = (Get-Content $PubKeyPath -Raw).Trim()

# Ensure directories
$ciDir    = Join-Path $VmRootDir "cloud-init"
$seedIso  = Join-Path $ciDir "cidata.iso"
$diffVhdx = Join-Path $VmRootDir "disk.vhdx"

New-Item -ItemType Directory -Force $VmRootDir | Out-Null
New-Item -ItemType Directory -Force $ciDir     | Out-Null

# -----------------------------
# Helper: Windows path -> WSL path
# -----------------------------
function To-WslPath([string]$winPath) {
    # C:\X\Y -> /mnt/c/X/Y
    return "/mnt/" + $winPath.Substring(0,1).ToLower() + $winPath.Substring(2).Replace('\','/')
}

# -----------------------------
# 1) Create differencing disk from golden base
# -----------------------------
if (Test-Path $diffVhdx) {
    throw "Differencing disk already exists: $diffVhdx"
}

New-VHD -Path $diffVhdx -ParentPath $BaseVhdxPath -Differencing | Out-Null

# Optional: Expand the *virtual* size of the differencing disk.
# (The guest partition/filesystem still needs growpart/resize2fs or cloud-init growpart.)
# Resize-VHD -Path $diffVhdx -SizeBytes 30GB

# -----------------------------
# 2) Create per-VM cloud-init seed (NoCloud)
# -----------------------------
# user-data: create devops user, install key packages, enable daemons
$userData = @"
#cloud-config
users:
  - name: root
    ssh_authorized_keys:
      - $pubKey

ssh_pwauth: false
disable_root: false

package_update: true
packages:
  - openssh-server
  - qemu-guest-agent
  - hyperv-daemons

runcmd:
  - systemctl enable --now ssh
  - systemctl enable --now hv-kvp-daemon
"@ -replace "`r`n","`n"

# meta-data: unique instance-id + hostname
$metaData = @"
instance-id: $VmName-$(Get-Date -Format yyyyMMddHHmmss)
local-hostname: $VmName
"@ -replace "`r`n","`n"

# network-config: your static addressing
$dnsYaml = ($DnsServers | ForEach-Object { $_ }) -join ","
$networkConfig = @"
version: 2
ethernets:
  eth0:
    addresses: [$IpAddress/$CidrPrefix]
    gateway4: $Gateway
    nameservers:
      addresses: [$dnsYaml]
"@ -replace "`r`n","`n"

# Write UTF-8 without BOM
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $ciDir "user-data"),      $userData,      $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $ciDir "meta-data"),      $metaData,      $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $ciDir "network-config"), $networkConfig, $utf8NoBom)

# Build cidata.iso via WSL genisoimage
$ciDirWsl = To-WslPath $ciDir
wsl.exe genisoimage -output "$ciDirWsl/cidata.iso" -volid cidata -joliet -rock `
  "$ciDirWsl/user-data" "$ciDirWsl/meta-data" "$ciDirWsl/network-config"

if (-not (Test-Path $seedIso)) {
    throw "cidata.iso was not created at: $seedIso"
}

# -----------------------------
# 3) Create and configure the VM
# -----------------------------
New-VM `
  -Name $VmName `
  -Generation 2 `
  -MemoryStartupBytes $MemStartup `
  -VHDPath $diffVhdx `
  -SwitchName $SwitchName `
  | Out-Null

Set-VMProcessor -VMName $VmName -Count $CpuCount
Set-VMProcessor -VMName $VmName -Maximum 100 -Reserve 10

# Debian cloud images: Secure Boot OFF typically avoids surprises
Set-VMFirmware -VMName $VmName -EnableSecureBoot Off

# Attach cidata.iso
Add-VMDvdDrive -VMName $VmName -Path $seedIso | Out-Null

# Start VM
Start-VM $VmName

# -----------------------------
# 4) Wait for SSH
# -----------------------------
Write-Host "VM '$VmName' started."
Write-Host "IP: $IpAddress"
Write-Host "Waiting for SSH on $IpAddress:22 ..."

for ($i = 0; $i -lt 180; $i++) {
    if (Test-NetConnection -ComputerName $IpAddress -Port 22 -InformationLevel Quiet) {
        Write-Host "Ready: ssh root@$IpAddress"
        exit 0
    }
    Start-Sleep 2
}

throw "SSH did not become available on $IpAddress:22. Check the VM console (cloud-init/ssh) and network settings."
