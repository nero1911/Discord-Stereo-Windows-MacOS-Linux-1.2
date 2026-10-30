# Install Discord Stereo Auto Updater for the current Windows user.
$ErrorActionPreference = "Stop"
$source = $PSScriptRoot
$destination = Join-Path $env:LOCALAPPDATA "DiscordStereoAutoUpdater"
New-Item -ItemType Directory -Path $destination -Force | Out-Null

$required = @("DiscordStereoAutoUpdater.ps1", "auto-update-manifest.json")
foreach ($file in $required) {
    $path = Join-Path $source $file
    if (-not (Test-Path -LiteralPath $path)) { throw "Required file is missing: $path" }
    Copy-Item -LiteralPath $path -Destination (Join-Path $destination $file) -Force
}

$monitor = Join-Path $destination "DiscordStereoAutoUpdater.ps1"
$exe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $monitor + '" -Watch'
$action = New-ScheduledTaskAction -Execute $exe -Argument $argument
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName "DiscordStereoAutoUpdater" -Action $action -Trigger $trigger -Settings $settings -Description "Monitors Discord voice-module updates and applies only exact-build verified stereo patches." -Force | Out-Null
Start-ScheduledTask -TaskName "DiscordStereoAutoUpdater"
Write-Host "Installed. The Windows background monitor is now running for this user."
Write-Host "Logs: $env:LOCALAPPDATA\DiscordStereoAutoUpdater\monitor.log"
