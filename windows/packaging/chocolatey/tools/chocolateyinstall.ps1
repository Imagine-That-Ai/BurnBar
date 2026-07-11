$ErrorActionPreference = 'Stop'

# OpenBurnBar — Chocolatey install script.
#
# Fetches the per-architecture PORTABLE zip from the GitHub release matching this
# package version, verifies its SHA256, and extracts it into the package tools folder.
# Chocolatey auto-shims OpenBurnBar.App.exe (the *.gui marker below makes that shim
# launch without a console window).
#
# The checksum64 / checksumArm64 values are RELEASE-STAMPED placeholders: the release
# pipeline (New-PortableZip.ps1 emits the .sha256 sidecars) rewrites them per version.

$packageName = 'openburnbar'
$toolsDir    = "$(Split-Path -Parent $MyInvocation.MyCommand.Definition)"
$version     = $env:ChocolateyPackageVersion
if ([string]::IsNullOrWhiteSpace($version)) { $version = '0.1.0' }

$baseUrl      = "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v$version"
$urlX64       = "$baseUrl/OpenBurnBar-$version-x64-portable.zip"
$urlArm64     = "$baseUrl/OpenBurnBar-$version-arm64-portable.zip"

# Release-stamped SHA256 placeholders (64 zero-hex until the Windows runner hashes them).
$checksumX64   = '0000000000000000000000000000000000000000000000000000000000000000'
$checksumArm64 = '0000000000000000000000000000000000000000000000000000000000000000'

# Pick the artifact for the host architecture (ARM64 Windows vs x64/x86-on-x64).
$arch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
if ($arch -eq 'ARM64') {
    $url      = $urlArm64
    $checksum = $checksumArm64
} else {
    $url      = $urlX64
    $checksum = $checksumX64
}

$packageArgs = @{
    PackageName   = $packageName
    UnzipLocation = $toolsDir
    Url64bit      = $url
    Checksum64    = $checksum
    ChecksumType64 = 'sha256'
}

Install-ChocolateyZipPackage @packageArgs

# Launch the shim as a GUI app (no lingering console window).
$exe = Join-Path $toolsDir 'OpenBurnBar.App.exe'
if (Test-Path $exe) {
    Set-Content -Path "$exe.gui" -Value '' -Encoding Ascii
}

# Do not shim bundled helper executables (crash dumper, WebView2 host, etc.).
Get-ChildItem -Path $toolsDir -Recurse -Include 'createdump.exe', 'msedgewebview2.exe' -ErrorAction SilentlyContinue |
    ForEach-Object { Set-Content -Path "$($_.FullName).ignore" -Value '' -Encoding Ascii }

Write-Host "OpenBurnBar $version installed. Run 'OpenBurnBar.App' or launch it from the Start menu shim."
