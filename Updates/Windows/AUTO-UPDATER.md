# Windows automatic stereo updates

This folder contains the Windows-only background monitor for Discord Stereo Hub.

## Behavior

- Installs a per-user Scheduled Task that starts at logon (no administrator rights required).
- Polls Discord Stable / PTB / Canary / Development voice modules every 20 seconds.
- Waits for discord_voice.node to stop changing before hashing it.
- Detects both Discord app-version changes and binary changes.
- Applies a patch only when auto-update-manifest.json contains an exact match for the Discord app version and the original discord_voice.node SHA-256.
- Makes a full voice-module backup before replacing only discord_voice.node. The existing interactive installer and its silent reinstall path are not invoked.
- Verifies the resulting patched binary SHA-256. On mismatch or failure, restores the full voice-module backup.
- Logs activity to %LOCALAPPDATA%\DiscordStereoAutoUpdater\monitor.log.

## Safety / current status

auto-update-manifest.json intentionally ships with an empty builds list. The current patched-binary feed does not publish a trustworthy source-build-to-patched-binary SHA-256 compatibility map. Without that mapping, blindly installing the latest pre-patched node after every Discord update could break voice or replace a newer Discord module with an incompatible build.

Therefore, the monitor and startup integration are implemented, but automatic patching remains fail-closed until an exact build profile is validated and added. Unknown builds are detected and logged; they are never modified.

A profile must contain:
- appVersion: exact app-* folder version
- sourceSha256: SHA-256 of the original Discord discord_voice.node
- patchedSha256: SHA-256 expected for the exact patched discord_voice.node payload
- patchedNodeUrl: HTTPS raw.githubusercontent.com URL for that exact patched binary
- fixerClientName: client selector accepted by DiscordVoiceFixer.ps1
- enabled: true only after the profile has been tested

Example (do not enable until the hashes have been measured and verified):

~~~json
{
  "schemaVersion": 1,
  "builds": [
    {
      "appVersion": "1.0.0000",
      "sourceSha256": "64-character-original-sha256",
      "patchedSha256": "64-character-patched-sha256",
      "patchedNodeUrl": "https://raw.githubusercontent.com/owner/repo/commit/path/discord_voice.node",
      "enabled": false
    }
  ]
}
~~~

## Install

1. Place DiscordStereoAutoUpdater.ps1, auto-update-manifest.json, and Install-AutoUpdater.ps1 in the same folder.
2. Run PowerShell as the current user:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-AutoUpdater.ps1
~~~

The installer copies the monitor, manifest, and existing Voice Fixer into %LOCALAPPDATA%\DiscordStereoAutoUpdater, registers a Scheduled Task at logon, and starts it immediately.

## Uninstall

Run:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-AutoUpdater.ps1
~~~

The scheduled task is removed. Logs, state, and safety backups are retained.

## Manual scan

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DiscordStereoAutoUpdater.ps1 -Once
~~~
