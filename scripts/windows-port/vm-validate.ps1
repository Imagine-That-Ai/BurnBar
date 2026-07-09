<#
.SYNOPSIS
    First-contact validation for the OpenBurnBar Windows port on a Win11 VM.

.DESCRIPTION
    Run this INSIDE the Win11 VM (or via SSH from the Mac) against a checkout of
    the repo. It reports the toolchain state, then builds + tests the Windows
    solution on the real target — the first time any of the WinUI XAML pages and
    net*-windows adapters are compiled outside CI.

    It is READ-ONLY except for build output: it clones/pulls nothing, signs
    nothing, installs nothing. Point -RepoRoot at an existing checkout.

.PARAMETER RepoRoot
    Path to the BurnBar repo checkout inside the VM (e.g. C:\src\BurnBar).

.PARAMETER Configuration
    Debug (default) or Release.

.EXAMPLE
    pwsh scripts/windows-port/vm-validate.ps1 -RepoRoot C:\src\BurnBar
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RepoRoot,
    [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Debug',
    [ValidateSet('', 'x86', 'x64', 'ARM64')] [string] $Platform = ''
)

$ErrorActionPreference = 'Stop'
$sln = Join-Path $RepoRoot 'windows\OpenBurnBar.sln'

function Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Resolve-Platform {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { 'ARM64'; break }
        'AMD64' { 'x64'; break }
        'x86' { 'x86'; break }
        default { 'x64' }
    }
}
function Check($label, $cmd) {
    try { $v = & $cmd 2>$null; Write-Host ("  [ok]   {0}: {1}" -f $label, $v) -ForegroundColor Green }
    catch { Write-Host ("  [MISS] {0}: not found" -f $label) -ForegroundColor Yellow }
}
function Resolve-MSBuildVersion {
    $msbuildCommand = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($msbuildCommand) {
        return (& $msbuildCommand.Source -version -nologo | Select-Object -Last 1)
    }

    $vswhereCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
    )
    foreach ($vswherePath in $vswhereCandidates) {
        if (-not (Test-Path -LiteralPath $vswherePath)) { continue }

        $installPath = & $vswherePath -latest -products * -requires Microsoft.Component.MSBuild -property installationPath 2>$null | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($installPath)) { continue }

        $msbuildCandidates = @(
            (Join-Path $installPath 'MSBuild\Current\Bin\arm64\MSBuild.exe'),
            (Join-Path $installPath 'MSBuild\Current\Bin\MSBuild.exe')
        )
        foreach ($candidate in $msbuildCandidates) {
            if (Test-Path -LiteralPath $candidate) {
                return (& $candidate -version -nologo | Select-Object -Last 1)
            }
        }
    }

    $buildToolsCandidates = @(
        'C:\BuildTools\MSBuild\Current\Bin\arm64\MSBuild.exe',
        'C:\BuildTools\MSBuild\Current\Bin\MSBuild.exe'
    )
    foreach ($candidate in $buildToolsCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (& $candidate -version -nologo | Select-Object -Last 1)
        }
    }

    throw 'MSBuild not found'
}
function Invoke-NativeStep($label, $file, [string[]]$arguments) {
    & $file @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$label failed with exit code $exitCode"
    }
}

if ([string]::IsNullOrWhiteSpace($Platform)) {
    $Platform = Resolve-Platform
}

Section 'Environment'
Write-Host "  Host      : $env:COMPUTERNAME"
Write-Host "  OS        : $((Get-CimInstance Win32_OperatingSystem).Caption) $((Get-CimInstance Win32_OperatingSystem).Version)"
Write-Host "  Arch      : $env:PROCESSOR_ARCHITECTURE"
Write-Host "  Platform  : $Platform"
Write-Host "  RepoRoot  : $RepoRoot"
if (-not (Test-Path $sln)) { throw "Solution not found at $sln — is -RepoRoot correct and the repo checked out?" }

Section 'Toolchain'
Check '.NET SDK'        { (dotnet --version) }
Check 'dotnet runtimes' { (dotnet --list-sdks | Select-Object -First 3) -join '; ' }
Check 'MSBuild'         { Resolve-MSBuildVersion }
Check 'Rust (cargo)'    { (cargo --version) }
Check 'Swift'           { (swift --version 2>&1 | Select-Object -First 1) }
try {
    $tpm = Get-Tpm -ErrorAction Stop
    Write-Host ("  [ok]   TPM present: {0}, ready: {1}" -f $tpm.TpmPresent, $tpm.TpmReady) -ForegroundColor Green
}
catch {
    $tpmError = $_.Exception.Message
    $tpmTool = Get-Command tpmtool.exe -ErrorAction SilentlyContinue
    if ($tpmTool) {
        $tpmToolOutput = & tpmtool.exe getdeviceinformation 2>$null
        $tpmPresent = $tpmToolOutput -match '^\s*-TPM Present:\s+True\s*$'
        $tpmVersionLine = $tpmToolOutput | Where-Object { $_ -match '^\s*-TPM Version:' } | Select-Object -First 1
        $tpmVersion = if ($tpmVersionLine -match ':\s*(.+)$') { $Matches[1].Trim() } else { 'unknown' }
        if ($tpmPresent) {
            Write-Host ("  [ok]   TPM present: True, version: {0} (tpmtool; Get-Tpm failed: {1})" -f $tpmVersion, $tpmError) -ForegroundColor Green
        }
        else {
            Write-Host ("  [MISS] TPM: Get-Tpm failed and tpmtool did not report a present TPM ({0})" -f $tpmError) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ("  [MISS] TPM: Get-Tpm failed and tpmtool.exe is unavailable ({0})" -f $tpmError) -ForegroundColor Yellow
    }
}

Section "Restore + Build ($Configuration)"
Push-Location $RepoRoot
try {
    Invoke-NativeStep 'dotnet restore' 'dotnet' @('restore', $sln, "-p:Platform=$Platform")
    Invoke-NativeStep 'dotnet build' 'dotnet' @('build', $sln, '-c', $Configuration, '--no-restore', "-p:Platform=$Platform")
    Write-Host "  [ok]   solution built on real Windows" -ForegroundColor Green
}
finally { Pop-Location }

Section "Test ($Configuration)"
Push-Location $RepoRoot
try {
    # Full suite; the loopback/FFI tests that skipped on macOS should now run.
    Invoke-NativeStep 'dotnet test' 'dotnet' @('test', $sln, '-c', $Configuration, '--no-build', '--logger', 'console;verbosity=minimal', "-p:Platform=$Platform")
    Write-Host "  [ok]   test suite completed" -ForegroundColor Green
}
finally { Pop-Location }

Section 'Next (agent-driven over SSH)'
Write-Host @"
  Solution builds + tests on real ARM64 Windows. From here the agent can:
    - C2  mint a TPM App Check attestation against this VM's vTPM (retires R14)
    - C3  build the Win2D particle host + measure 60fps on ARM64 (WINUI-017)
    - C4  exercise the computer-use SendInput/UIA/capture loop
    - C5  seal an E2EE payload here -> open on the Mac (retires the C5 deferral)
    - C6  cargo-build the crates + run the native-shim msvc loopback (FFI-008)
    - C7  screenshot each surface running with real data (bundle section 5)
  See docs/windows-port/TONIGHT_PUNCHLIST.md.
"@ -ForegroundColor Cyan
