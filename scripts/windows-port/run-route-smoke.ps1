param(
    [string]$AppExe,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "..\..\windows\route-smoke"),
    [int]$TimeoutMilliseconds = 9000,
    [string[]]$Routes = @(
        "dashboard",
        "quota",
        "insights",
        "sessionLogs",
        "memory",
        "missionControl",
        "budget",
        "dataControlCenter",
        "chat",
        "switcher",
        "onboarding",
        "settings",
        "elderWand"
    )
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($env:DOTNET_ROLL_FORWARD)) {
    $env:DOTNET_ROLL_FORWARD = "Major"
}


function Resolve-AppExe {
    param([string]$Requested)

    if (![string]::IsNullOrWhiteSpace($Requested)) {
        if (!(Test-Path -LiteralPath $Requested)) {
            throw "AppExe not found: $Requested"
        }
        return (Resolve-Path -LiteralPath $Requested).Path
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    $matches = Get-ChildItem -LiteralPath (Join-Path $repoRoot "windows\app\OpenBurnBar.App\bin") -Filter "OpenBurnBar.App.exe" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    if ($matches.Count -eq 0) {
        throw "OpenBurnBar.App.exe not found. Build windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj first, or pass -AppExe."
    }

    return $matches[0].FullName
}

$app = Resolve-AppExe -Requested $AppExe
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$results = @()
foreach ($route in $Routes) {
    $routeOut = Join-Path $OutputDirectory $route
    New-Item -ItemType Directory -Force -Path $routeOut | Out-Null

    $args = @(
        "--route-smoke", $route,
        "--route-smoke-out", $routeOut,
        "--route-smoke-timeout-ms", $TimeoutMilliseconds.ToString()
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $app
    $startInfo.UseShellExecute = $false
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    foreach ($argument in $args) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw "Failed to start OpenBurnBar.App.exe for route smoke: $route"
    }
    $completed = $process.WaitForExit($TimeoutMilliseconds + 4000)
    if (!$completed) {
        try { $process.Kill($true) } catch { }
        $result = [pscustomobject]@{
            route = $route
            exitCode = 124
            timedOut = $true
            nearUniform = $true
            resultPath = $null
            screenshotPath = $null
            message = "Route smoke timed out"
        }
        $results += $result
        continue
    }

    $jsonPath = Join-Path $routeOut "$route-result.json"
    if (Test-Path -LiteralPath $jsonPath) {
        $payload = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        $result = [pscustomobject]@{
            route = $route
            exitCode = [int]$process.ExitCode
            timedOut = $false
            nearUniform = [bool]$payload.NearUniform
            resultPath = $jsonPath
            screenshotPath = $payload.ScreenshotPath
            message = $payload.Message
        }
    } else {
        $result = [pscustomobject]@{
            route = $route
            exitCode = [int]$process.ExitCode
            timedOut = $false
            nearUniform = $true
            resultPath = $null
            screenshotPath = $null
            message = "Route smoke result JSON was not written"
        }
    }

    $results += $result
}

$summary = [pscustomobject]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    appExe = $app
    outputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
    routes = $results
    failedRoutes = @($results | Where-Object { $_.exitCode -ne 0 -or $_.nearUniform })
}

$summaryPath = Join-Path $OutputDirectory "route-smoke-summary.json"
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$summary | ConvertTo-Json -Depth 6

if ($summary.failedRoutes.Count -gt 0) {
    exit 1
}

exit 0
