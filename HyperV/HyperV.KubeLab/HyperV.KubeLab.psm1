Set-StrictMode -Version Latest

# ---------------------------
# Helpers
# ---------------------------

function ConvertTo-WslPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WinPath
    )
    # C:\X\Y -> /mnt/c/X/Y
    "/mnt/" + $WinPath.Substring(0,1).ToLower() + $WinPath.Substring(2).Replace('\','/')
}

function Test-CommandExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CommandName
    )
    return [bool](Get-Command $CommandName -ErrorAction SilentlyContinue)
}

function New-NoCloudSeedIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CiDir,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$UserData,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MetaData,

        [Parameter()]
        [string]$NetworkConfig
    )

    if (-not (Test-CommandExists -CommandName "wsl.exe")) {
        throw "wsl.exe not found. Install WSL."
    }

    New-Item -ItemType Directory -Force $CiDir | Out-Null

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $userPath = Join-Path $CiDir "user-data"
    $metaPath = Join-Path $CiDir "meta-data"
    $netPath  = Join-Path $CiDir "network-config"
    $isoPath  = Join-Path $CiDir "cidata.iso"

    [System.IO.File]::WriteAllText($userPath, $UserData, $utf8NoBom)
    [System.IO.File]::WriteAllText($metaPath, $MetaData, $utf8NoBom)

    $args = @((ConvertTo-WslPath $userPath), (ConvertTo-WslPath $metaPath))

    if ($PSBoundParameters.ContainsKey("NetworkConfig") -and $NetworkConfig) {
        [System.IO.File]::WriteAllText($netPath, $NetworkConfig, $utf8NoBom)
        $args += (ConvertTo-WslPath $netPath)
    }

    # Build ISO using genisoimage in WSL
    # Assumes genisoimage exists in your WSL distro
    $isoWsl = ConvertTo-WslPath $isoPath

    & wsl.exe genisoimage -output "$isoWsl" -volid cidata -joliet -rock @args | Out-Null

    if (-not (Test-Path $isoPath)) {
        throw "cidata.iso was not created at: $isoPath"
    }

    return $isoPath
}

function Wait-TcpPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IpAddress,

        [Parameter()]
        [ValidateRange(1,65535)]
        [int]$Port = 22,

        [Parameter()]
        [ValidateRange(5,3600)]
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName $IpAddress -Port $Port -InformationLevel Quiet) { return $true }
        Start-Sleep 2
    }
    return $false
}

function Start-VMWithOneRebootIfUnhealthy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VmName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IpAddress,

        [Parameter()]
        [ValidateRange(1,65535)]
        [int]$Port = 22,

        [Parameter()]
        [ValidateRange(10,3600)]
        [int]$FirstBootTimeoutSeconds = 180,

        [Parameter()]
        [ValidateRange(10,3600)]
        [int]$SecondBootTimeoutSeconds = 180
    )

    Start-VM -Name $VmName | Out-Null

    Write-Host "Waiting for TCP/$Port on $IpAddress (first boot)..."
    if (Wait-TcpPort -IpAddress $IpAddress -Port $Port -TimeoutSeconds $FirstBootTimeoutSeconds) {
        return
    }

    Write-Warning "VM not healthy on first boot. Power-cycling once (no SSH)..."
    Stop-VM -Name $VmName -TurnOff -Force
    Start-Sleep 5
    Start-VM -Name $VmName | Out-Null

    Write-Host "Waiting for TCP/$Port on $IpAddress (second boot)..."
    if (-not (Wait-TcpPort -IpAddress $IpAddress -Port $Port -TimeoutSeconds $SecondBootTimeoutSeconds)) {
        throw "VM did not become healthy after one power-cycle. Check VM console."
    }
}

# ---------------------------
# Public API
# ---------------------------

function New-KubeLabVm {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9\-_]{0,62}$')]
        [string]$VmName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SwitchName,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$BaseVhdxPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VmRootDir,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$UserData,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MetaData,

        [Parameter()]
        [string]$NetworkConfig,

        [Parameter()]
        [ValidateRange(1,64)]
        [int]$CpuCount = 2,

        [Parameter()]
        [ValidateScript({ $_ -ge 256MB })]
        [UInt64]$MemStartupBytes = 1GB,

        [Parameter()]
        [ValidatePattern('^(\d{1,3}\.){3}\d{1,3}$')]
        [string]$IpAddress,

        [Parameter()]
        [switch]$DisableCheckpoints,

        [Parameter()]
        [switch]$OneRebootWorkaround
    )

    if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
        throw "VM '$VmName' already exists."
    }

    # Ensure folder structure
    New-Item -ItemType Directory -Force $VmRootDir | Out-Null
    $ciDir    = Join-Path $VmRootDir "cloud-init"
    $seedIso  = Join-Path $ciDir "cidata.iso"
    $diffVhdx = Join-Path $VmRootDir "disk.vhdx"

    if (Test-Path $diffVhdx) {
        throw "Differencing disk already exists: $diffVhdx"
    }

    if ($PSCmdlet.ShouldProcess($VmName, "Create differencing disk, seed ISO, and VM")) {

        # Create differencing disk
        New-VHD -Path $diffVhdx -ParentPath $BaseVhdxPath -Differencing | Out-Null

        # Create seed ISO
        $seedIso = New-NoCloudSeedIso -CiDir $ciDir -UserData $UserData -MetaData $MetaData -NetworkConfig $NetworkConfig

        # Create VM
        New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemStartupBytes -VHDPath $diffVhdx -SwitchName $SwitchName | Out-Null
        Set-VMProcessor -VMName $VmName -Count $CpuCount | Out-Null
        Set-VMFirmware  -VMName $VmName -EnableSecureBoot Off | Out-Null
        Add-VMDvdDrive  -VMName $VmName -Path $seedIso | Out-Null

        if ($DisableCheckpoints) {
            # Prevent hidden AVHDX layers from checkpoints
            Set-VM -Name $VmName -CheckpointType Disabled -AutomaticCheckpointsEnabled $false | Out-Null
        }

        # Start VM (+ optional one reboot workaround)
        if ($IpAddress) {
            if ($OneRebootWorkaround) {
                Start-VMWithOneRebootIfUnhealthy -VmName $VmName -IpAddress $IpAddress -Port 22
            } else {
                Start-VM -Name $VmName | Out-Null
                Write-Host "Waiting for TCP/22 on $IpAddress ..."
                if (-not (Wait-TcpPort -IpAddress $IpAddress -Port 22 -TimeoutSeconds 180)) {
                    throw "VM started but TCP/22 not reachable within timeout. Check console/network."
                }
            }
        } else {
            Start-VM -Name $VmName | Out-Null
        }

        # Return details
        return [pscustomobject]@{
            VmName   = $VmName
            VmRoot   = $VmRootDir
            DiffVhdx = $diffVhdx
            SeedIso  = $seedIso
            Ip       = $IpAddress
        }
    }
}

Export-ModuleMember -Function New-KubeLabVm, New-NoCloudSeedIso, ConvertTo-WslPath, Wait-TcpPort, Start-VMWithOneRebootIfUnhealthy
