
$vmName = "ubuntu-dev-03"
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
$vmDisk = "C:\Images\Current\$vmName\disk.vhdx"
New-Item -ItemType Directory -Force $vmDisk | Out-Null

New-Item -ItemType Directory -Force (Split-Path $vmDisk) | Out-Null
Copy-Item $golden $vmDisk

New-VM `
  -Name $vmName `
  -Generation 2 `
  -MemoryStartupBytes 12GB `
  -VHDPath $vmDisk `
  -SwitchName "Default Switch"

Add-VMDvdDrive -VMName $vmName -Path "$ciDir\cidata.iso"

Set-VMFirmware -VMName $vmName -EnableSecureBoot Off

Start-VM $vmName

$ip = $null
for ($i = 0; $i -lt 120 -and -not $ip; $i++) {
    $ip = Get-VMNetworkAdapter -VMName $vmName |
        Select-Object -ExpandProperty IPAddresses |
        Where-Object { $_ -like "*.*" } |
        Select-Object -First 1
    Start-Sleep 2
}
if (-not $ip) {
    throw "Failed to get IP address of VM $vmName"
}
echo "VM is starting up. Waiting for TCP connection to become available at $ip ..."
# Wait for SSH
while (-not (Test-NetConnection -ComputerName $ip -Port 22 -InformationLevel Quiet)) {
    Start-Sleep 5
}

$dvd = Get-VMDvdDrive -VMName $vmName -ErrorAction SilentlyContinue
if ($dvd) {
    Remove-VMDvdDrive -VMName $vmName `
        -ControllerNumber $dvd.ControllerNumber `
        -ControllerLocation $dvd.ControllerLocation
}

Start-Sleep 5
# clean up cloud-init files
Remove-Item $ciDir -Recurse -Force