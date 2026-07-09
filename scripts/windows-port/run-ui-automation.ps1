param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$Configuration = "Debug",
    [ValidateSet("x64", "ARM64")]
    [string]$Platform,
    [string]$OutputDirectory,
    [int]$TimeoutMilliseconds = 12000,
    [string[]]$Routes = @(),
    [switch]$Direct,
    [switch]$SkipBuild,
    [switch]$SkipSemanticProbe
)

$ErrorActionPreference = "Stop"

if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows) -eq $false) {
    throw "Windows UI automation must run inside the Windows VM desktop session."
}

if ([string]::IsNullOrWhiteSpace($Platform)) {
    $Platform = if ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { "ARM64" } else { "x64" }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $OutputDirectory = Join-Path $RepoRoot ".artifacts\windows-ui-automation\$stamp"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$appProject = Join-Path $RepoRoot "windows\app\OpenBurnBar.App\OpenBurnBar.App.csproj"
$harnessProject = Join-Path $RepoRoot "windows\tests\ui-automation-harness\OpenBurnBar.UiAutomationHarness\OpenBurnBar.UiAutomationHarness.csproj"

if (-not $SkipBuild) {
    & dotnet build $appProject -c $Configuration -p:Platform=$Platform -p:EnableWindowsTargeting=true
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & dotnet build $harnessProject -c $Configuration -p:Platform=$Platform -p:EnableWindowsTargeting=true
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$appExe = Get-ChildItem -LiteralPath (Join-Path $RepoRoot "windows\app\OpenBurnBar.App\bin") -Filter "OpenBurnBar.App.exe" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*\$Configuration\*" -and $_.FullName -like "*\$Platform\*" } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

if ($null -eq $appExe) {
    $appExe = Get-ChildItem -LiteralPath (Join-Path $RepoRoot "windows\app\OpenBurnBar.App\bin") -Filter "OpenBurnBar.App.exe" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

if ($null -eq $appExe) {
    throw "OpenBurnBar.App.exe not found. Build the app first or run without -SkipBuild."
}

$harnessArgs = @(
    "run",
    "--no-build",
    "--project", $harnessProject,
    "--configuration", $Configuration,
    "-p:Platform=$Platform",
    "--",
    "--repo-root", $RepoRoot,
    "--app-exe", $appExe.FullName,
    "--output", $OutputDirectory,
    "--timeout-ms", $TimeoutMilliseconds.ToString()
)

foreach ($route in $Routes) {
    if (-not [string]::IsNullOrWhiteSpace($route)) {
        $harnessArgs += @("--route", $route)
    }
}

if ($SkipSemanticProbe) {
    $harnessArgs += "--skip-semantic-probe"
}

if ($Direct) {
    & dotnet @harnessArgs
    exit $LASTEXITCODE
}

$runnerPath = Join-Path $OutputDirectory "run-harness-task.ps1"
$exitPath = Join-Path $OutputDirectory "exit-code.txt"
$consolePath = Join-Path $OutputDirectory "harness-console.log"
$quotedArgs = ($harnessArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
Set-Content -LiteralPath $runnerPath -Encoding UTF8 -Value @"
`$ErrorActionPreference = "Stop"
Set-Location "$RepoRoot"
try {
    `$previousErrorActionPreference = `$ErrorActionPreference
    `$ErrorActionPreference = "Continue"
    `$dotnetOutput = & dotnet $quotedArgs 2>&1
    `$code = `$LASTEXITCODE
    `$dotnetOutput | ForEach-Object {
        if (`$_ -is [System.Management.Automation.ErrorRecord]) {
            `$_.Exception.Message
        } else {
            `$_.ToString()
        }
    } | Set-Content -LiteralPath "$consolePath" -Encoding UTF8
    `$ErrorActionPreference = `$previousErrorActionPreference
} catch {
    `$ErrorActionPreference = "Continue"
    `$code = 1
    `$_.Exception.ToString() | Tee-Object -FilePath "$consolePath" -Append
}
Set-Content -LiteralPath "$exitPath" -Value `$code -Encoding ASCII
exit `$code
"@

$taskName = "OpenBurnBarUiHarness-" + [Guid]::NewGuid().ToString("N")
$pwsh = Get-Command pwsh.exe -All -ErrorAction SilentlyContinue |
    Where-Object { -not ($_.Source -like "*\Microsoft\WindowsApps\pwsh.exe") } |
    Select-Object -First 1
if ($null -ne $pwsh) {
    $shell = $pwsh.Source
} else {
    $shell = (Get-Command powershell.exe).Source
}

$action = New-ScheduledTaskAction -Execute $shell -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
$userId = (& whoami).Trim()
if ([string]::IsNullOrWhiteSpace($userId)) {
    $userId = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN) -or $env:USERDOMAIN -eq "WORKGROUP") { $env:USERNAME } else { "$env:USERDOMAIN\$env:USERNAME" }
}
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal | Out-Null
    Start-ScheduledTask -TaskName $taskName

    $deadline = (Get-Date).AddMilliseconds(($TimeoutMilliseconds + 5000) * [Math]::Max(1, 13 + $Routes.Count) + 120000)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $exitPath) {
            $codeText = (Get-Content -LiteralPath $exitPath -Raw).Trim()
            $code = [int]$codeText
            if (Test-Path -LiteralPath $consolePath) {
                Get-Content -LiteralPath $consolePath -Raw
            }
            exit $code
        }

        Start-Sleep -Seconds 2
    }

    throw "Timed out waiting for scheduled task '$taskName'. Console log: $consolePath"
}
finally {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
