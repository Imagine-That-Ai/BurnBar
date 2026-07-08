$ErrorActionPreference = 'Stop'

# OpenBurnBar — Chocolatey uninstall script.
#
# Removes the extracted portable files tracked at install time. In PORTABLE mode the
# app keeps its database/logs/settings in a Data\ subfolder next to the executable, so
# removing the package directory leaves nothing behind. Per-user data (only present if
# the .portable marker was deleted) under %LOCALAPPDATA%\OpenBurnBar is intentionally
# preserved so a reinstall keeps history; delete it manually for a full wipe.

$packageName = 'openburnbar'
$toolsDir    = "$(Split-Path -Parent $MyInvocation.MyCommand.Definition)"

# Best-effort: stop a running instance so file removal isn't blocked.
Get-Process -Name 'OpenBurnBar.App' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Uninstall-ChocolateyZipPackage -PackageName $packageName -ZipFileName 'OpenBurnBar-*-portable.zip'

# Clean up shim markers we created.
Get-ChildItem -Path $toolsDir -Recurse -Include '*.gui', '*.ignore' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "OpenBurnBar removed. Per-user data under %LOCALAPPDATA%\OpenBurnBar (if any) was left intact."
