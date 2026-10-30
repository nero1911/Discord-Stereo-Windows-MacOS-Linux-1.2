# Uninstall the current-user startup task. Backups and logs are intentionally retained.
$ErrorActionPreference = "Stop"
$task = Get-ScheduledTask -TaskName "DiscordStereoAutoUpdater" -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName "DiscordStereoAutoUpdater" -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "DiscordStereoAutoUpdater" -Confirm:$false
    Write-Host "Discord Stereo Auto Updater startup task removed."
} else {
    Write-Host "Startup task was not installed."
}
Write-Host "Logs and safety backups were retained in %LOCALAPPDATA%\DiscordStereoAutoUpdater."
