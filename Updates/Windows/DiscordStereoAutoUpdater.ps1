# Discord Stereo Auto Updater - Windows background monitor
# Safe-by-default: applies a patch only when an exact app-version + source SHA-256
# profile exists in auto-update-manifest.json and the resulting patched SHA-256 matches.
[CmdletBinding()]
param([switch]$Watch, [switch]$Once)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:DataRoot = Join-Path $env:LOCALAPPDATA "DiscordStereoAutoUpdater"
$script:StatePath = Join-Path $script:DataRoot "state.json"
$script:LogPath = Join-Path $script:DataRoot "monitor.log"
$script:ManifestPath = Join-Path $PSScriptRoot "auto-update-manifest.json"
$script:ManifestUrl = "https://raw.githubusercontent.com/nero1911/Discord-Stereo-Windows-MacOS-Linux-1.2/main/Updates/Windows/auto-update-manifest.json"
$script:PollSeconds = 20
$script:DiscordProcessNames = @("Discord", "DiscordCanary", "DiscordPTB", "DiscordDevelopment")

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    try {
        if (-not (Test-Path $script:DataRoot)) { New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null }
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch {}
}

function Get-State {
    if (Test-Path -LiteralPath $script:StatePath) {
        try { return (Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable) } catch {}
    }
    return @{}
}

function Save-State {
    param([hashtable]$State)
    $tmp = "$script:StatePath.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:StatePath -Force
}

function Get-Manifest {
    $manifest = $null
    try {
        $response = Invoke-RestMethod -Uri $script:ManifestUrl -TimeoutSec 15 -Headers @{ "Cache-Control" = "no-cache" }
        if ($response.schemaVersion -eq 1 -and $response.builds -is [array]) { $manifest = $response }
    } catch { Write-Log "Remote build manifest unavailable: $($_.Exception.Message)" "WARN" }
    if (-not $manifest -and (Test-Path -LiteralPath $script:ManifestPath)) {
        try {
            $local = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($local.schemaVersion -eq 1) { $manifest = $local }
        } catch {}
    }
    if (-not $manifest) { throw "No valid auto-update manifest is available." }
    return $manifest
}

function Get-DiscordTargets {
    $roots = @(
        @{ Name = "Discord"; Path = (Join-Path $env:LOCALAPPDATA "Discord") },
        @{ Name = "Discord PTB"; Path = (Join-Path $env:LOCALAPPDATA "DiscordPTB") },
        @{ Name = "Discord Canary"; Path = (Join-Path $env:LOCALAPPDATA "DiscordCanary") },
        @{ Name = "Discord Development"; Path = (Join-Path $env:LOCALAPPDATA "DiscordDevelopment") }
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.Path)) { continue }
        $apps = Get-ChildItem -LiteralPath $root.Path -Directory -Filter "app-*" -ErrorAction SilentlyContinue
        foreach ($app in $apps) {
            $version = $null
            if ($app.Name -match '^app-([0-9]+(?:\.[0-9]+){1,3})$') { $version = $matches[1] }
            if (-not $version) { continue }
            $modules = Join-Path $app.FullName "modules"
            if (-not (Test-Path -LiteralPath $modules)) { continue }
            $voiceModules = Get-ChildItem -LiteralPath $modules -Directory -Filter "discord_voice*" -ErrorAction SilentlyContinue
            foreach ($vm in $voiceModules) {
                $nested = Join-Path $vm.FullName "discord_voice"
                $voiceDir = if (Test-Path -LiteralPath $nested) { $nested } else { $vm.FullName }
                $node = Join-Path $voiceDir "discord_voice.node"
                if (Test-Path -LiteralPath $node -PathType Leaf) {
                    [pscustomobject]@{
                        ClientName = $root.Name
                        Root = $root.Path
                        AppPath = $app.FullName
                        AppVersion = $version
                        VoiceDir = $voiceDir
                        NodePath = $node
                    }
                }
            }
        }
    }
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-DiscordRunning {
    return ($null -ne (Get-Process -Name $script:DiscordProcessNames -ErrorAction SilentlyContinue))
}

function Wait-FileStable {
    param([string]$Path)
    $previous = $null
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            $current = "{0}:{1}" -f $item.Length, $item.LastWriteTimeUtc.Ticks
            if ($previous -and $previous -ne $current) { $previous = $current; Start-Sleep -Seconds 5; continue }
            $previous = $current
        } catch { return $false }
        Start-Sleep -Seconds 5
    }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return ($previous -eq ("{0}:{1}" -f $item.Length, $item.LastWriteTimeUtc.Ticks) -and $item.Length -gt 1MB)
    } catch { return $false }
}

function Restore-VoiceDirectory {
    param([string]$BackupPath, [string]$VoiceDir)
    foreach ($name in $script:DiscordProcessNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    if (-not (Test-Path -LiteralPath $BackupPath)) { throw "Safety backup is missing: $BackupPath" }
    if (Test-Path -LiteralPath $VoiceDir) { Remove-Item -LiteralPath $VoiceDir -Recurse -Force }
    Copy-Item -LiteralPath $BackupPath -Destination $VoiceDir -Recurse -Force
}

function Invoke-VerifiedPatch {
    param($Target, $Profile)
    if (-not $Profile.enabled) {
        Write-Log "Matching profile exists but is disabled for $($Target.ClientName) $($Target.AppVersion)." "WARN"
        return $false
    }
    if ($Profile.sourceSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $Profile.patchedSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        Write-Log "Manifest profile has invalid SHA-256 values; refusing to patch." "ERROR"
        return $false
    }
    $fixer = Join-Path $PSScriptRoot "DiscordVoiceFixer.ps1"
    if (-not (Test-Path -LiteralPath $fixer)) {
        Write-Log "DiscordVoiceFixer.ps1 was not found beside the monitor; refusing to patch." "ERROR"
        return $false
    }
    if (Test-DiscordRunning) {
        Write-Log "Discord is still running; patch postponed until it is closed." "WARN"
        return $false
    }

    $backupRoot = Join-Path $script:DataRoot "backups"
    if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
    $backupPath = Join-Path $backupRoot ("{0}_{1}_{2}" -f ($Target.ClientName -replace '[^A-Za-z0-9]+','_'), $Target.AppVersion, (Get-Date -Format "yyyyMMdd_HHmmss"))
    Copy-Item -LiteralPath $Target.VoiceDir -Destination $backupPath -Recurse -Force
    Write-Log "Created safety backup: $backupPath"

    try {
        if ([string]::IsNullOrWhiteSpace([string]$Profile.fixerClientName)) { throw "Manifest fixerClientName is missing." }
        $clientArg = [string]$Profile.fixerClientName
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $fixer + '" -Silent -FixClient "' + $clientArg.Replace('"','\"') + '"'
        Write-Log "Starting verified Voice Fixer for $($Target.ClientName) app-$($Target.AppVersion)."
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne 0) { throw "Voice Fixer exited with code $($process.ExitCode)." }

        $node = Join-Path $Target.VoiceDir "discord_voice.node"
        if (-not (Test-Path -LiteralPath $node)) { throw "Patched discord_voice.node was not found after installation." }
        $actual = Get-Sha256 -Path $node
        if ($actual -ne ([string]$Profile.patchedSha256).ToLowerInvariant()) {
            throw "Patched binary SHA-256 mismatch. Expected $($Profile.patchedSha256), received $actual."
        }
        Write-Log "Verified patch installed successfully for $($Target.ClientName) $($Target.AppVersion)." "OK"
        return $true
    } catch {
        Write-Log "Patch failed verification: $($_.Exception.Message). Restoring the complete voice-module backup." "ERROR"
        try {
            Restore-VoiceDirectory -BackupPath $backupPath -VoiceDir $Target.VoiceDir
            Write-Log "Original voice module restored successfully." "OK"
        } catch {
            Write-Log "CRITICAL: automatic restore failed: $($_.Exception.Message). Backup remains at $backupPath" "CRITICAL"
        }
        return $false
    }
}

function Invoke-Scan {
    $state = Get-State
    $manifest = Get-Manifest
    $targets = @(Get-DiscordTargets)
    foreach ($target in $targets) {
        try {
            if (-not (Wait-FileStable -Path $target.NodePath)) {
                Write-Log "Voice module is changing or unavailable; postponed: $($target.NodePath)" "WARN"
                continue
            }
            $hash = Get-Sha256 -Path $target.NodePath
            $key = $target.NodePath.ToLowerInvariant()
            $previous = $state[$key]
            if (-not $previous) {
                $state[$key] = @{ sha256 = $hash; appVersion = $target.AppVersion; firstSeenUtc = (Get-Date).ToUniversalTime().ToString("o") }
                Write-Log "Baseline recorded: $($target.ClientName) app-$($target.AppVersion)."
                continue
            }
            if ($previous.sha256 -eq $hash -and $previous.appVersion -eq $target.AppVersion) { continue }

            Write-Log "Discord update detected: $($target.ClientName) app-$($previous.appVersion) -> app-$($target.AppVersion)."
            $profile = @($manifest.builds | Where-Object {
                $_.appVersion -eq $target.AppVersion -and
                ([string]$_.sourceSha256).ToLowerInvariant() -eq $hash
            } | Select-Object -First 1)

            if ($profile.Count -eq 0) {
                Write-Log "No exact verified profile for app-$($target.AppVersion) / $hash. No patch was applied; original file left untouched." "WARN"
                $state[$key] = @{ sha256 = $hash; appVersion = $target.AppVersion; pending = $true; lastSeenUtc = (Get-Date).ToUniversalTime().ToString("o") }
                continue
            }
            if (Test-DiscordRunning) {
                Write-Log "Discord is running; verified update will be retried on the next scan after it closes." "WARN"
                continue
            }
            if (Invoke-VerifiedPatch -Target $target -Profile $profile[0]) {
                $newHash = Get-Sha256 -Path $target.NodePath
                $state[$key] = @{ sha256 = $newHash; appVersion = $target.AppVersion; pending = $false; lastPatchedUtc = (Get-Date).ToUniversalTime().ToString("o") }
            } else {
                $state[$key] = @{ sha256 = $hash; appVersion = $target.AppVersion; pending = $true; lastFailureUtc = (Get-Date).ToUniversalTime().ToString("o") }
            }
        } catch {
            Write-Log "Scan failed for $($target.NodePath): $($_.Exception.Message)" "ERROR"
        }
    }
    Save-State -State $state
}

if (-not (Test-Path $script:DataRoot)) { New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null }
Write-Log "Monitor started (Windows)."
if ($Once) { Invoke-Scan; exit 0 }
if ($Watch) {
    while ($true) {
        Invoke-Scan
        Start-Sleep -Seconds $script:PollSeconds
    }
}
Write-Host "Use -Watch for background monitoring or -Once for a single scan."
