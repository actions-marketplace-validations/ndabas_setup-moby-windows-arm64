<#
.SYNOPSIS
    Installs a Windows ARM64 build of the moby Docker engine and starts it as a service.

.DESCRIPTION
    Downloads a release of setup-moby-windows-arm64 (or uses a local build),
    verifies its checksum, copies docker.exe and dockerd.exe to -InstallPath,
    adds that directory to the machine PATH, writes daemon.json, registers
    dockerd as the "docker" Windows service and starts it.

    Re-running the script upgrades or downgrades an installation made by it:
    the service is stopped, the binaries are replaced and it is started again.

    Pipe access: dockerd creates \\.\pipe\docker_engine with a DACL that only
    allows Administrators and SYSTEM. Its "group" setting appends read/write
    ACEs for a comma-separated list of users and/or groups, so this script
    adds -Principal to "group" in daemon.json, letting those users run docker
    without elevation.

    The Windows "Containers" feature is enabled if needed; that requires a
    reboot, after which the script must be run again.

    All dockerd settings are written to daemon.json and the service is
    registered without flags, because a setting given both as a flag and in
    daemon.json makes dockerd refuse to start.

.PARAMETER Version
    Release to install: "latest", or a moby release tag such as
    "docker-v29.9.0" ("29.9.0" and "v29.9.0" are also accepted).

.PARAMETER Repository
    GitHub repository to download the release from.

.PARAMETER SourcePath
    Install from a local zip or directory containing docker.exe and
    dockerd.exe instead of downloading a release.

.PARAMETER InstallPath
    Directory to install docker.exe and dockerd.exe into.

.PARAMETER Principal
    Users and/or groups to grant access to the docker pipe. Defaults to the
    current user. Pass an empty array to leave "group" unchanged.

.PARAMETER ConfigFile
    dockerd's config file. Defaults to dockerd's default location on Windows.

.PARAMETER Isolation
    Default container isolation ("process" or "hyperv"), written to
    "exec-opts" in daemon.json. Pass an empty string to leave it unchanged.

.PARAMETER StorageSize
    If set (e.g. "300GB"), sets storage-opts size=<value> in daemon.json; the
    default 20 GB container sandbox is too small for large images.

.PARAMETER DataRoot
    If set (e.g. "D:\docker"), sets data-root in daemon.json so images and
    containers are stored there. Must be on NTFS. Existing images are not
    moved; they will need to be pulled again.

.PARAMETER DefenderExclusion
    Exclude the data-root from Microsoft Defender scanning. Real-time scanning
    of every file dockerd writes makes committing large layers many times
    slower.

.PARAMETER NoPath
    Don't add -InstallPath to the machine PATH.

.PARAMETER NoStart
    Install and configure, but don't start the service.

.PARAMETER Force
    Replace a "docker" service that runs a dockerd.exe from another location.

.EXAMPLE
    .\Install-Moby.ps1

    Installs the latest release and lets the current user use docker.

.EXAMPLE
    .\Install-Moby.ps1 -Version docker-v29.9.0 -StorageSize 300GB -DataRoot D:\docker -DefenderExclusion

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ndabas/setup-moby-windows-arm64/main/Install-Moby.ps1))) -Version latest
#>
[CmdletBinding()]
param(
    [string] $Version = 'latest',
    [string] $Repository = 'ndabas/setup-moby-windows-arm64',
    [string] $SourcePath,
    [string] $InstallPath = (Join-Path $env:ProgramFiles 'moby'),
    [string[]] $Principal = @([Security.Principal.WindowsIdentity]::GetCurrent().Name),
    [string] $ConfigFile = (Join-Path $env:ProgramData 'docker\config\daemon.json'),
    [ValidateSet('process', 'hyperv', '')]
    [string] $Isolation = 'process',
    [string] $StorageSize,
    [string] $DataRoot,
    [switch] $DefenderExclusion,
    [switch] $NoPath,
    [switch] $NoStart,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ServiceName = 'docker'
$Asset = 'docker-windows-arm64.zip'
$DefaultConfigFile = Join-Path $env:ProgramData 'docker\config\daemon.json'

function Get-DockerService {
    Get-CimInstance Win32_Service -Filter "Name = '$ServiceName'"
}

function Wait-DockerReady([string] $Docker, [int] $TimeoutSeconds = 180) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        & $Docker version *> $null
        if ($LASTEXITCODE -eq 0) { return }
        if ((Get-Date) -gt $deadline) {
            Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = $ServiceName } -MaxEvents 20 -ErrorAction SilentlyContinue |
                Sort-Object TimeCreated | Format-Table TimeCreated, LevelDisplayName, Message -Wrap | Out-String -Width 300 | Write-Host
            throw 'dockerd did not become ready in time'
        }
        Start-Sleep -Seconds 2
    }
}

#region Preflight

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must be run from an elevated (Administrator) PowerShell.'
}

# PROCESSOR_ARCHITECTURE is AMD64 in an emulated x64 process; the machine-wide value is the native one.
$arch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
if ($arch -ne 'ARM64') { throw "This build is for Windows ARM64; this machine is $arch." }

if ([Net.ServicePointManager]::SecurityProtocol -ne 0) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Fail early on names dockerd won't be able to resolve (it would refuse to start).
foreach ($p in $Principal) {
    try {
        $sid = ([Security.Principal.NTAccount]$p).Translate([Security.Principal.SecurityIdentifier])
        Write-Host "Granting pipe access to $p ($sid)"
    } catch {
        throw "Cannot resolve '$p' to a SID: $($_.Exception.Message)"
    }
}

$InstallPath = [IO.Path]::GetFullPath($InstallPath)
$dockerdPath = Join-Path $InstallPath 'dockerd.exe'
$service = Get-DockerService
$existingService = $service.PathName
$replaceService = $existingService -and $existingService.IndexOf($dockerdPath, [StringComparison]::OrdinalIgnoreCase) -lt 0
if ($replaceService -and -not $Force) {
    throw "A '$ServiceName' service already exists and runs another dockerd: $existingService. Use -Force to replace it."
}

$servicePid = if ($service) { $service.ProcessId } else { 0 }
$strays = @(Get-CimInstance Win32_Process -Filter "Name = 'dockerd.exe'" | Where-Object { $_.ProcessId -ne $servicePid })
if ($strays) {
    throw "dockerd is already running outside the '$ServiceName' service (PID $($strays.ProcessId -join ', ')): stop it first. Command line was: $($strays[0].CommandLine)"
}

$rebootRequired = $false
$containers = Get-WindowsOptionalFeature -Online -FeatureName Containers
if ($containers.State -ne 'Enabled') {
    Write-Host 'Enabling the Windows Containers feature...'
    $result = Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart
    $rebootRequired = $result.RestartNeeded
}

#endregion

#region Get the binaries

$staging = Join-Path ([IO.Path]::GetTempPath()) ("moby-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $staging | Out-Null
try {
    if ($SourcePath) {
        $SourcePath = (Resolve-Path $SourcePath).Path
        Write-Host "Installing from $SourcePath"
        if (Test-Path $SourcePath -PathType Leaf) {
            Expand-Archive $SourcePath -DestinationPath $staging -Force
        } else {
            Copy-Item (Join-Path $SourcePath '*.exe') $staging
        }
        $tag = 'local'
    } else {
        $userAgent = 'setup-moby-windows-arm64'
        $headers = @{ 'Accept' = 'application/vnd.github+json' }
        $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
        if ($token) { $headers['Authorization'] = "Bearer $token" }

        if ($Version -eq 'latest' -or -not $Version) {
            # The repository's "Latest" release may be a release of the action itself (e.g. v1),
            # so pick the highest docker-vX.Y.Z release instead.
            $releases = Invoke-RestMethod "https://api.github.com/repos/$Repository/releases?per_page=100" -Headers $headers -UserAgent $userAgent
            $tag = $releases | Where-Object { -not $_.draft -and -not $_.prerelease -and $_.tag_name -match '^docker-v\d+\.\d+\.\d+$' } |
                ForEach-Object { $_.tag_name } |
                Sort-Object { [version]($_ -replace '^docker-v', '') } -Descending | Select-Object -First 1
            if (-not $tag) { throw "Could not find a docker-v* release in $Repository" }
        } elseif ($Version -like 'docker-*') {
            $tag = $Version
        } else {
            $tag = 'docker-v' + ($Version -replace '^v', '')
        }
        Write-Host "Downloading $tag from $Repository"

        $zip = Join-Path $staging $Asset
        $base = "https://github.com/$Repository/releases/download/$tag"
        Invoke-WebRequest "$base/$Asset" -OutFile $zip -UserAgent $userAgent -UseBasicParsing
        Invoke-WebRequest "$base/$Asset.sha256" -OutFile "$zip.sha256" -UserAgent $userAgent -UseBasicParsing

        $expected = ((Get-Content "$zip.sha256" -Raw).Trim() -split '\s+')[0]
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "Checksum mismatch for $Asset`: expected $expected, got $actual" }

        Expand-Archive $zip -DestinationPath $staging -Force
        Remove-Item $zip, "$zip.sha256"
    }

    foreach ($exe in 'docker.exe', 'dockerd.exe') {
        if (-not (Test-Path (Join-Path $staging $exe))) { throw "$exe not found in the release" }
    }

    #endregion

    #region Install

    if ($existingService) {
        Write-Host "Stopping the '$ServiceName' service..."
        Stop-Service -Name $ServiceName
    }
    if ($replaceService) {
        Write-Host "Removing the existing '$ServiceName' service: $existingService"
        sc.exe delete $ServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe delete $ServiceName failed with exit code $LASTEXITCODE" }
        $existingService = $null
    }

    New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
    Copy-Item (Join-Path $staging '*.exe') $InstallPath -Force
    Write-Host "Installed $tag to $InstallPath"
} finally {
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $NoPath) {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($machinePath -split ';') -notcontains $InstallPath) {
        [Environment]::SetEnvironmentVariable('Path', ($machinePath.TrimEnd(';') + ';' + $InstallPath), 'Machine')
        Write-Host "Added $InstallPath to the machine PATH; open a new shell to pick it up."
    }
    if (($env:Path -split ';') -notcontains $InstallPath) { $env:Path += ";$InstallPath" }
}

#endregion

#region Configure daemon.json

$config = [ordered]@{}
if (Test-Path $ConfigFile) {
    $existing = Get-Content -Raw $ConfigFile | ConvertFrom-Json
    foreach ($prop in $existing.PSObject.Properties) { $config[$prop.Name] = $prop.Value }
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $ConfigFile) | Out-Null
}

if ($Principal) {
    $groups = [System.Collections.Generic.List[string]]::new()
    if ($config['group']) {
        $config['group'].Split(',') | ForEach-Object { if ($_.Trim()) { $groups.Add($_.Trim()) } }
    }
    foreach ($p in $Principal) {
        if (-not ($groups | Where-Object { $_ -ieq $p })) { $groups.Add($p) }
    }
    $config['group'] = $groups -join ','
}

if ($Isolation) {
    $opts = @($config['exec-opts'] | Where-Object { $_ -and $_ -notmatch '^isolation=' })
    $config['exec-opts'] = @($opts) + "isolation=$Isolation"
}

if ($StorageSize) {
    $opts = @($config['storage-opts'] | Where-Object { $_ -and $_ -notmatch '^size=' })
    $config['storage-opts'] = @($opts) + "size=$StorageSize"
}

if ($DataRoot) {
    $DataRoot = [IO.Path]::GetFullPath($DataRoot)
    $fs = (Get-Volume -DriveLetter $DataRoot[0]).FileSystem
    if ($fs -ne 'NTFS') { throw "data-root must be on NTFS for Windows containers; $($DataRoot[0]): is $fs" }
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    $config['data-root'] = $DataRoot
}

if ($DefenderExclusion) {
    $root = if ($config['data-root']) { $config['data-root'] } else { Join-Path $env:ProgramData 'docker' }
    Add-MpPreference -ExclusionPath $root
    Write-Host "Excluded $root from Microsoft Defender scanning"
}

# dockerd rejects a UTF-8 BOM, which Windows PowerShell's Set-Content -Encoding UTF8 would write.
$json = [pscustomobject]$config | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($ConfigFile, $json, [Text.UTF8Encoding]::new($false))
Write-Host "Updated $ConfigFile :"
Write-Host $json

#endregion

#region Register and start the service

if ($existingService) {
    $conflicts = @{
        '(\s|^)(-G|--group)(\s|=)'   = 'group'
        '--exec-opt'                 = 'exec-opts'
        '--storage-opt'              = 'storage-opts'
        '--data-root|(\s|^)-g(\s|=)' = 'data-root'
    }
    foreach ($pattern in $conflicts.Keys) {
        if ($existingService -match $pattern -and $config.Contains($conflicts[$pattern])) {
            Write-Warning "The '$ServiceName' service is registered with a flag for '$($conflicts[$pattern])', which is also set in $ConfigFile; dockerd will refuse to start. Re-register it with: dockerd --unregister-service; dockerd --register-service"
        }
    }
} else {
    $registerArgs = @('--register-service', '--service-name', $ServiceName)
    if ($ConfigFile -ne $DefaultConfigFile) { $registerArgs += @('--config-file', $ConfigFile) }
    & $dockerdPath @registerArgs
    if ($LASTEXITCODE -ne 0) { throw "dockerd --register-service failed with exit code $LASTEXITCODE" }
    Write-Host "Registered the '$ServiceName' service"
}

if ($rebootRequired) {
    Write-Warning 'The Containers feature was enabled and Windows must be restarted. After restarting, the docker service will start automatically.'
} elseif ($NoStart) {
    Write-Host "Not starting the service; start it with: Start-Service $ServiceName"
} else {
    Write-Host "Starting the '$ServiceName' service..."
    Start-Service -Name $ServiceName
    $docker = Join-Path $InstallPath 'docker.exe'
    Wait-DockerReady $docker
    & $docker version
    Write-Host 'Docker is ready. Users granted pipe access can now run docker from a non-elevated shell.'
}

#endregion
