$vmName   = "bookworm_base"
$cpuCount = 3
$memSize  = 4GB
$switch   = "VirtualSwitch1"   # Prefer an External switch for k8s labs
$ip = "192.168.137.10"

# Your SSH public key
$pubKey = (Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw).Trim()

if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
    throw "VM '$vmName' already exists. Aborting."
}

# Paths
$vmDir   = "C:\Images\Current\kube\$vmName"
$ciDir   = "$vmDir\cloud-init"
$seedIso = "$ciDir\cidata.iso"

New-Item -ItemType Directory -Force $vmDir | Out-Null
New-Item -ItemType Directory -Force $ciDir | Out-Null

### --- 1) Create cloud-init NoCloud seed (user-data, meta-data) ---
$userData = @"
#cloud-config
users:
  - name: devops
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $pubKey

ssh_pwauth: false
disable_root: true
package_update: true
packages:
  - qemu-guest-agent
  - hyperv-daemons
runcmd:
  - systemctl enable --now hv-kvp-daemon
"@ -replace "`r`n","`n"

$netConfig = @"
version: 2
ethernets:
  eth0:
    addresses: [$ip/24]
    gateway4: 192.168.137.1
    nameservers:
      addresses: [1.1.1.1,8.8.8.8]
"@ -replace "`r`n","`n"

[System.IO.File]::WriteAllText("$ciDir\network-config", $netConfig, (New-Object System.Text.UTF8Encoding($false)))

######################## test user-data with password auth ########################
# $userData = @"
# #cloud-config
# users:
#   - name: devops
#     groups: [adm, sudo]
#     sudo: ALL=(ALL) NOPASSWD:ALL
#     shell: /bin/bash

# chpasswd:
#   list: |
#     devops:TempPass123
#   expire: False

# ssh_pwauth: true
# package_update: true
# packages:
#   - qemu-guest-agent
#   - hyperv-daemons
# runcmd:
#   - systemctl enable --now hv-kvp-daemon
# "@ -replace "`r`n","`n"

$metaData = @"
instance-id: $vmName-$(Get-Date -Format yyyyMMddHHmmss)
local-hostname: $vmName
"@ -replace "`r`n","`n"

# Write UTF-8 without BOM
[System.IO.File]::WriteAllText("$ciDir\user-data", $userData, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText("$ciDir\meta-data", $metaData, (New-Object System.Text.UTF8Encoding($false)))

# Convert Windows path to WSL path
function To-WslPath([string]$winPath) {
    return "/mnt/" + $winPath.Substring(0,1).ToLower() + $winPath.Substring(2).Replace('\','/')
}
$ciDirWsl = To-WslPath $ciDir

# Create seed ISO (volume id MUST be cidata for NoCloud)
wsl.exe genisoimage -output "$ciDirWsl/cidata.iso" -volid cidata -joliet -rock `
  "$ciDirWsl/user-data" "$ciDirWsl/meta-data" "$ciDirWsl/network-config"

if (-not (Test-Path $seedIso)) {
  throw "cidata.iso was not created at $seedIso"
}

# --- 2) Download Debian cloud image (qcow2) ---
# You can place the qcow2 manually too; this is just a path variable for the file.
$qcow2 = "C:\ISOs\debian-12-genericcloud-amd64.qcow2"

# If you already downloaded it, skip this.
# (Keeping this as a manual step avoids brittle URL assumptions.)
if (-not (Test-Path $qcow2)) {
    throw "Place a Debian 12 genericcloud qcow2 at: $qcow2 (then re-run)."
}

# --- 3) Convert qcow2 -> vhdx for Hyper-V ---
$vhdx = "$vmDir\disk.vhdx"
$qcow2Wsl = To-WslPath $qcow2
$vhdxWsl  = To-WslPath $vhdx

# Convert to fixed VHDX (more predictable)
wsl.exe qemu-img convert -p -f qcow2 -O vhdx "$qcow2Wsl" "$vhdxWsl"

if (-not (Test-Path $vhdx)) {
    throw "VHDX conversion failed; disk not found at $vhdx"
}

# Optional: expand the disk (cloud images are often small by default)
# Resize-VHD requires the VM to be off (it is, right now)
# Resize-VHD -Path $vhdx -SizeBytes 30GB

# --- 4) Create VM and attach disks ---
New-VM `
    -Name $vmName `
    -Generation 2 `
    -MemoryStartupBytes $memSize `
    -VHDPath $vhdx `
    -SwitchName $switch `
    | Out-Null

Set-VMProcessor -VMName $vmName -Count $cpuCount
Set-VMProcessor -VMName $vmName -Maximum 100 -Reserve 10

# Debian cloud images typically boot fine with Secure Boot OFF in Gen2
Set-VMFirmware -VMName $vmName -EnableSecureBoot Off

# Attach the NoCloud seed ISO
Add-VMDvdDrive -VMName $vmName -Path $seedIso | Out-Null

Start-VM $vmName

# --- 5) Wait for IP, then SSH readiness ---
# $ip = $null
for ($i = 0; $i -lt 180 -and -not $ip; $i++) {
    $ip = Get-VMNetworkAdapter -VMName $vmName |
        Select-Object -ExpandProperty IPAddresses |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
        Select-Object -First 1
    Start-Sleep 2
}

if (-not $ip) { throw "Failed to get IP address for VM $vmName" }

Write-Host "VM IP: $ip"
Write-Host "Waiting for SSH on $ip:22 ..."

for ($i = 0; $i -lt 120; $i++) {
    if (Test-NetConnection -ComputerName $ip -Port 22 -InformationLevel Quiet) { break }
    Start-Sleep 2
}

if (-not (Test-NetConnection -ComputerName $ip -Port 22 -InformationLevel Quiet)) {
    throw "SSH did not become available. Check cloud-init status from console."
}

Write-Host "Ready: ssh devops@$ip"
