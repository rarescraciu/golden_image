Import-Module "C:\code\HyperV\HyperV.KubeLab\HyperV.KubeLab.psm1" -Force

$VmName        = "test_VM_001"
$SwitchName    = "kube_thw_cluster"
$CpuCount      = 2
$MemStartup    = 2GB

$IpAddress     = "192.168.138.100"
$CidrPrefix    = 24
$Gateway       = "192.168.138.1"
$DnsServers    = @("1.1.1.1","8.8.8.8")

$BaseVhdxPath  = "C:\Images\Golden\debian12\debian12-base-20g.vhdx"
$VmRootDir     = "C:\Images\Current\$VmName"

$PubKeyPath    = "$env:USERPROFILE\.ssh\id_ed25519.pub"
$pubKey        = (Get-Content $PubKeyPath -Raw).Trim()

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

$metaData = @"
instance-id: $VmName-$(Get-Date -Format yyyyMMddHHmmss)
local-hostname: $VmName
"@ -replace "`r`n","`n"

$dnsYaml = ($DnsServers -join ",")
$networkConfig = @"
version: 2
ethernets:
  eth0:
    addresses: [$IpAddress/$CidrPrefix]
    gateway4: $Gateway
    nameservers:
      addresses: [$dnsYaml]
"@ -replace "`r`n","`n"

New-KubeLabVm `
  -VmName $VmName `
  -SwitchName $SwitchName `
  -BaseVhdxPath $BaseVhdxPath `
  -VmRootDir $VmRootDir `
  -UserData $userData `
  -MetaData $metaData `
  -NetworkConfig $networkConfig `
  -CpuCount $CpuCount `
  -MemStartupBytes $MemStartup `
  -IpAddress $IpAddress `
  -DisableCheckpoints `
  -OneRebootWorkaround
