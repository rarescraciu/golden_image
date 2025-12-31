Set-StrictMode -Version Latest

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WinPath)
    return "/mnt/" + $WinPath.Substring(0,1).ToLower() + $WinPath.Substring(2).Replace('\','/')
}

function New-NoCloudSeedIso {
    param(
        [Parameter(Mandatory)][string]$CiDir,
        [Parameter(Mandatory)][string]$UserData,
        [Parameter(Mandatory)][string]$MetaData,
        [string]$NetworkConfig
    )

    New-Item -ItemType Directory -Force $CiDir | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $userPath = Join-Path $CiDir "user-data"
    $metaPath = Join-Path $CiDir "meta-data"
    $netPath  = Join-Path $CiDir "network-config"
    $isoPath  = Join-Path $CiDir "cidata.iso"

    [System.IO.File]::WriteAllText($userPath, $UserData, $utf8NoBom)
    [System.IO.File]::WriteAllText($metaPath, $MetaData, $utf8NoBom)

    $args = @((ConvertTo-WslPath $userPath), (ConvertTo-WslPath $metaPath))

    if ($NetworkConfig) {
        [System.IO.File]::WriteAllText($netPath, $NetworkConfig, $utf8NoBom)
        $args += (ConvertTo-WslPath $netPath)
    }

    $ciDirWsl = ConvertTo-WslPath $CiDir
    $isoWsl   = ConvertTo-WslPath $isoPath

    # Build ISO
    wsl.exe genisoimage -output "$isoWsl" -volid cidata -joliet -rock @args | Out-Null

    if (-not (Test-Path $isoPath)) {
        throw "cidata.iso was not created at: $isoPath"
    }

    return $isoPath
}

function Wait-TcpPort {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$Port = 22,
        [int]$TimeoutSeconds = 180
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName $Ip -Port $Port -InformationLevel Quiet) { return $true }
        Start-Sleep 2
    }
    return $false
}

function Start-VMWithOneRebootIfUnhealthy {
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$IpAddress,
        [int]$Port = 22,
        [int]$FirstBootTimeoutSeconds = 180,
        [int]$SecondBootTimeoutSeconds = 180
    )

    Start-VM -Name $VmName | Out-Null

    Write-Host "Waiting for TCP/$Port on $IpAddress (first boot)..."
    if (Wait-TcpPort -Ip $IpAddress -Port $Port -TimeoutSeconds $FirstBootTimeoutSeconds) {
        return
    }

    Write-Warning "Not healthy on first boot. Power-cycling once (no SSH)..."
    Stop-VM -Name $VmName -TurnOff -Force
    Start-Sleep 5
    Start-VM -Name $VmName | Out-Null

    Write-Host "Waiting for TCP/$Port on $IpAddress (second boot)..."
    if (-not (Wait-TcpPort -Ip $IpAddress -Port $Port -TimeoutSeconds $SecondBootTimeoutSeconds)) {
        throw "VM did not become healthy after one power-cycle. Check VM console."
    }
}

function New-KubeLabVm {
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$SwitchName,
        [Parameter(Mandatory)][string]$BaseVhdxPath,
        [Parameter(Mandatory)][string]$VmRootDir,
        [Parameter(Mandatory)][string]$UserData,
        [Parameter(Mandatory)][string]$MetaData,
        [string]$NetworkConfig,
        [int]$CpuCount = 2,
        [UInt64]$MemStartupBytes = 1GB,
        [string]$IpAddress,
        [switch]$DisableCheckpoints
    )

    if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
        throw "VM '$VmName' already exists."
    }
    if (-not (Test-Path $BaseVhdxPath)) {
        throw "Base VHDX not found: $BaseVhdxPath"
    }

    New-Item -ItemType Directory -Force $VmRootDir | Out-Null
    $ciDir    = Join-Path $VmRootDir "cloud-init"
    $diffVhdx = Join-Path $VmRootDir "disk.vhdx"

    # Differencing disk
    New-VHD -Path $diffVhdx -ParentPath $BaseVhdxPath -Differencing | Out-Null

    # Seed ISO
    $seedIso = New-NoCloudSeedIso -CiDir $ciDir -UserData $UserData -MetaData $MetaData -NetworkConfig $NetworkConfig

    # VM create
    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemStartupBytes -VHDPath $diffVhdx -SwitchName $SwitchName | Out-Null
    Set-VMProcessor -VMName $VmName -Count $CpuCount | Out-Null
    Set-VMFirmware  -VMName $VmName -EnableSecureBoot Off | Out-Null
    Add-VMDvdDrive  -VMName $VmName -Path $seedIso | Out-Null

    if ($DisableCheckpoints) {
        Set-VM -Name $VmName -CheckpointType Disabled -AutomaticCheckpointsEnabled $false | Out-Null
    }

    # Start + optional one reboot
    if ($IpAddress) {
        Start-VMWithOneRebootIfUnhealthy -VmName $VmName -IpAddress $IpAddress -Port 22
        Write-Host "Ready: ssh root@$IpAddress"
    } else {
        Start-VM -Name $VmName | Out-Null
        Write-Host "VM started (no IP provided for readiness check)."
    }

    # Return useful info
    [pscustomobject]@{
        VmName   = $VmName
        DiffVhdx = $diffVhdx
        SeedIso  = $seedIso
        VmRoot   = $VmRootDir
        Ip       = $IpAddress
    }
}

Export-ModuleMember -Function `
    ConvertTo-WslPath, New-NoCloudSeedIso, Wait-TcpPort, Start-VMWithOneRebootIfUnhealthy, New-KubeLabVm
