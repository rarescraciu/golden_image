
$vmName = "ubuntu-dev-01"
$pubKey = (Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw).Trim()

$ciDir = "C:\code\packer\create-vm\cloud-init"
New-Item -ItemType Directory -Force $ciDir | Out-Null


$userData = @"
#cloud-config
users:
  - name: devops
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - "$pubKey"
"@ -replace "`r`n","`n"

$metaData = @"
instance-id: $vmName-$(Get-Date -Format yyyyMMddHHmmss)
local-hostname: $vmName
"@ -replace "`r`n","`n"

# Write UTF-8 *without BOM*
[System.IO.File]::WriteAllText("$ciDir\user-data", $userData, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText("$ciDir\meta-data", $metaData, (New-Object System.Text.UTF8Encoding($false)))

# Convert C:\... to /mnt/c/... for WSL
$ciDirWsl = "/mnt/" + $ciDir.Substring(0,1).ToLower() + $ciDir.Substring(2).Replace('\','/')

# Create ISO in the Windows folder (via WSL)
wsl.exe genisoimage -output "$ciDirWsl/cidata.iso" -volid cidata -joliet -rock `
  "$ciDirWsl/user-data" "$ciDirWsl/meta-data"

if (-not (Test-Path "$ciDir\cidata.iso")) {
  throw "cidata.iso was not created at $ciDir\cidata.iso"
}


$golden = "C:\Images\Golden\ubuntu-dev-golden-2025.12.vhdx"
$vmDisk = "C:\Images\Current\ubuntu-dev-01\disk.vhdx"

New-Item -ItemType Directory -Force (Split-Path $vmDisk) | Out-Null
Copy-Item $golden $vmDisk

New-VM `
  -Name "ubuntu-dev-01" `
  -Generation 2 `
  -MemoryStartupBytes 12GB `
  -VHDPath $vmDisk `
  -SwitchName "Default Switch"

Add-VMDvdDrive -VMName $vmName -Path "$ciDir\cidata.iso"

Set-VMFirmware -VMName $vmName -EnableSecureBoot Off

Start-VM $vmName

