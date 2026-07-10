<#
.SYNOPSIS
    Capture OpenBurnBar WinUI screenshots and UI Automation trees from an
    interactive Windows desktop.

.DESCRIPTION
    This script must run in the active console user's session, not session 0.
    The parent foundation host runner is responsible for launching it through
    WTS token duplication or an equivalent reviewed interactive mechanism.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RepoRoot,
    [Parameter(Mandatory = $true)] [string] $OutputDir,
    [string] $AppExe = '',
    [int] $HoldMilliseconds = 8000
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string] $Path) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Write-JsonFile([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $Value | ConvertTo-Json -Depth 64 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function Get-StringSha256([string] $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-SafeName([string] $Value) {
    $safe = $Value
    foreach ($invalid in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace($invalid, '-')
    }
    $safe.Replace(':', '-').Replace('/', '-').Replace('\', '-')
}

function ConvertTo-WindowsCommandLineArgument([string] $Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes += 1
            continue
        }
        if ($character -eq [char]'"') {
            [void]$builder.Append([char]'\', (($backslashes * 2) + 1))
            [void]$builder.Append('"')
        } else {
            if ($backslashes -gt 0) {
                [void]$builder.Append([char]'\', $backslashes)
            }
            [void]$builder.Append($character)
        }
        $backslashes = 0
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]'\', ($backslashes * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Stop-ProcessTree([System.Diagnostics.Process] $Process) {
    if ($null -eq $Process -or $Process.HasExited) { return }
    try {
        $killer = [System.Diagnostics.Process]::Start('taskkill.exe', "/PID $($Process.Id) /T /F")
        if ($null -ne $killer) {
            [void]$killer.WaitForExit(10000)
            $killer.Dispose()
        }
    } catch {
        try { $Process.Kill() } catch { }
    }
}

function Resolve-AppExe([string] $Requested) {
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        if (-not (Test-Path -LiteralPath $Requested -PathType Leaf)) {
            throw "AppExe not found: $Requested"
        }
        return (Resolve-Path -LiteralPath $Requested).Path
    }

    $matches = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'windows\app\OpenBurnBar.App\bin') -Filter 'OpenBurnBar.App.exe' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    if ($matches.Count -eq 0) {
        throw 'OpenBurnBar.App.exe not found. Build the WinUI app before running UIA collection.'
    }
    return $matches[0].FullName
}

function Initialize-Uia {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
}

function Get-ElementValue($Element) {
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $pattern) {
            return $pattern.Current.Value
        }
    } catch { }
    return $null
}

function Get-ElementPatterns($Element) {
    $patterns = @()
    foreach ($entry in @(
        @{ name = 'invoke'; pattern = [System.Windows.Automation.InvokePattern]::Pattern },
        @{ name = 'value'; pattern = [System.Windows.Automation.ValuePattern]::Pattern },
        @{ name = 'selectionItem'; pattern = [System.Windows.Automation.SelectionItemPattern]::Pattern },
        @{ name = 'text'; pattern = [System.Windows.Automation.TextPattern]::Pattern },
        @{ name = 'scroll'; pattern = [System.Windows.Automation.ScrollPattern]::Pattern }
    )) {
        try {
            if ($null -ne $Element.GetCurrentPattern($entry.pattern)) {
                $patterns += $entry.name
            }
        } catch { }
    }
    return $patterns
}

function Convert-UiaElement($Element, [int] $Depth) {
    if ($null -eq $Element) { return $null }
    $rect = $Element.Current.BoundingRectangle
    $node = [ordered]@{
        name = $Element.Current.Name
        automationId = $Element.Current.AutomationId
        className = $Element.Current.ClassName
        controlType = $Element.Current.ControlType.ProgrammaticName
        localizedControlType = $Element.Current.LocalizedControlType
        isEnabled = $Element.Current.IsEnabled
        hasKeyboardFocus = $Element.Current.HasKeyboardFocus
        isKeyboardFocusable = $Element.Current.IsKeyboardFocusable
        value = Get-ElementValue $Element
        patterns = Get-ElementPatterns $Element
        boundingRectangle = [ordered]@{
            x = $rect.X
            y = $rect.Y
            width = $rect.Width
            height = $rect.Height
        }
        children = @()
    }

    if ($Depth -le 0) {
        return $node
    }

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $child = $walker.GetFirstChild($Element)
    $count = 0
    while ($null -ne $child -and $count -lt 250) {
        $node.children += Convert-UiaElement $child ($Depth - 1)
        $child = $walker.GetNextSibling($child)
        $count += 1
    }
    return $node
}

function Find-WindowForProcess([int] $ProcessId, [int] $TimeoutMs = 10000) {
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $ProcessId)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            $condition)
        if ($windows.Count -gt 0) {
            return $windows[0]
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Find-ByAutomationId($Root, [string] $AutomationId) {
    if ($null -eq $Root) { return $null }
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Set-UiaValue($Root, [string] $AutomationId, [string] $Value) {
    $element = Find-ByAutomationId $Root $AutomationId
    if ($null -eq $element) {
        throw "UIA element not found: $AutomationId"
    }
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $pattern.SetValue($Value)
}

function Invoke-Uia($Root, [string] $AutomationId) {
    $element = Find-ByAutomationId $Root $AutomationId
    if ($null -eq $element) {
        throw "UIA element not found: $AutomationId"
    }
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
}

function Assert-UiaElement($Root, [string] $AutomationId) {
    $element = Find-ByAutomationId $Root $AutomationId
    if ($null -eq $element) {
        throw "Expected UIA element not found: $AutomationId"
    }
    return [ordered]@{
        automationId = $AutomationId
        name = $element.Current.Name
        isEnabled = $element.Current.IsEnabled
        controlType = $element.Current.ControlType.ProgrammaticName
        value = Get-ElementValue $element
    }
}

function Save-Screenshot($Element, [string] $Path) {
    try {
        $rect = $Element.Current.BoundingRectangle
        if ($rect.Width -lt 10 -or $rect.Height -lt 10) {
            throw 'Window bounds are empty.'
        }
        $bitmap = [System.Drawing.Bitmap]::new([int]$rect.Width, [int]$rect.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen([int]$rect.X, [int]$rect.Y, 0, 0, $bitmap.Size)
            $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
            return [ordered]@{ path = $Path; status = 'captured' }
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
    catch {
        return [ordered]@{ path = $Path; status = 'failed'; error = $_.Exception.Message }
    }
}

function New-HelperExe([string] $Dir, [string] $Name) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $source = Join-Path $env:SystemRoot 'System32\where.exe'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        $source = Join-Path $env:SystemRoot 'System32\whoami.exe'
    }
    $target = Join-Path $Dir $Name
    Copy-Item -LiteralPath $source -Destination $target -Force
    return $target
}

function Invoke-RouteScenario {
    param(
        [Parameter(Mandatory = $true)] [string] $Id,
        [Parameter(Mandatory = $true)] [string] $Route,
        [scriptblock] $Action = $null,
        [scriptblock] $PrepareProfile = $null,
        [string[]] $RequiredAutomationIds = @('chat.surface'),
        [string] $ProfileRoot = ''
    )

    $safe = Get-SafeName $Id
    $scenarioDir = Join-Path $OutputDir "scenarios\$safe"
    New-Item -ItemType Directory -Force -Path $scenarioDir | Out-Null
    if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
        $ProfileRoot = Join-Path $OutputDir "profiles\$safe"
    }
    $localAppData = Join-Path $ProfileRoot 'LocalAppData'
    New-Item -ItemType Directory -Force -Path $localAppData | Out-Null
    if ($null -ne $PrepareProfile) {
        & $PrepareProfile $localAppData
    }

    $routeOut = Join-Path $scenarioDir 'route-smoke'
    New-Item -ItemType Directory -Force -Path $routeOut | Out-Null

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:ResolvedAppExe
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = Split-Path -Parent $script:ResolvedAppExe
    $arguments = @(
        '--route-smoke', $Route,
        '--route-smoke-out', $routeOut,
        '--route-smoke-timeout-ms', '15000',
        '--route-smoke-hold-ms', [Math]::Max(0, $HoldMilliseconds).ToString()
    )
    $psi.Arguments = ($arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }) -join ' '
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $localAppData
    $psi.EnvironmentVariables['OPENBURNBAR_CLI_DISABLE'] = '1'

    $process = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $process) {
        throw "Failed to start app for $Id"
    }

    $window = Find-WindowForProcess -ProcessId $process.Id
    $actions = @()
    $artifacts = @()
    if ($null -eq $window) {
        $actions += [ordered]@{ action = 'findWindow'; status = 'failed' }
    }
    else {
        $actions += [ordered]@{ action = 'findWindow'; status = 'captured'; processId = $process.Id }
        foreach ($automationId in $RequiredAutomationIds) {
            try {
                $element = Assert-UiaElement $window $automationId
                $actions += [ordered]@{ action = 'requireAutomationId'; status = 'captured'; element = $element }
            }
            catch {
                $actions += [ordered]@{ action = 'requireAutomationId'; status = 'failed'; automationId = $automationId; error = $_.Exception.Message }
            }
        }

        $beforeTree = Join-Path $scenarioDir 'uia-before.json'
        Write-JsonFile $beforeTree ([ordered]@{
            capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            processId = $process.Id
            focus = Convert-UiaElement ([System.Windows.Automation.AutomationElement]::FocusedElement) 0
            tree = Convert-UiaElement $window 7
        })
        $artifacts += $beforeTree
        $screenBefore = Join-Path $scenarioDir 'screenshot-before.png'
        $artifacts += (Save-Screenshot $window $screenBefore).path

        if ($null -ne $Action) {
            try {
                $actionResult = & $Action $window $scenarioDir $localAppData
                $actions += [ordered]@{ action = 'scenarioAction'; status = 'captured'; result = $actionResult }
            }
            catch {
                $actions += [ordered]@{ action = 'scenarioAction'; status = 'failed'; error = $_.Exception.Message }
            }

            Start-Sleep -Milliseconds 750
            $afterTree = Join-Path $scenarioDir 'uia-after.json'
            Write-JsonFile $afterTree ([ordered]@{
                capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                processId = $process.Id
                focus = Convert-UiaElement ([System.Windows.Automation.AutomationElement]::FocusedElement) 0
                tree = Convert-UiaElement $window 7
            })
            $artifacts += $afterTree
            $screenAfter = Join-Path $scenarioDir 'screenshot-after.png'
            $artifacts += (Save-Screenshot $window $screenAfter).path
        }
    }

    if (-not $process.WaitForExit(30000 + [Math]::Max(0, $HoldMilliseconds))) {
        Stop-ProcessTree $process
    }
    $exitCode = if ($process.HasExited) { $process.ExitCode } else { 124 }

    $routeResult = Join-Path $routeOut "$Route-result.json"
    if (Test-Path -LiteralPath $routeResult) {
        $artifacts += $routeResult
    }
    $routePng = Join-Path $routeOut "$Route.png"
    if (Test-Path -LiteralPath $routePng) {
        $artifacts += $routePng
    }

    return [ordered]@{
        id = $Id
        route = $Route
        status = if (($actions | Where-Object { $_.status -eq 'failed' }).Count -eq 0 -and $exitCode -eq 0) { 'captured' } else { 'failed' }
        processId = $process.Id
        exitCode = $exitCode
        actor = [ordered]@{
            identitySha256 = Get-StringSha256 ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
            sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        }
        localAppData = $localAppData
        actions = $actions
        artifacts = @($artifacts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Initialize-ProfileStorage([string] $LocalAppData) {
    $profile = Split-Path -Parent $LocalAppData
    [void](Invoke-RouteScenario -Id ('profile.init.' + [Guid]::NewGuid().ToString('N')) -Route 'chat' -ProfileRoot $profile)
    $db = Join-Path $LocalAppData 'OpenBurnBar\openburnbar.sqlite'
    if (-not (Test-Path -LiteralPath $db -PathType Leaf)) {
        throw "Expected initialized database not found: $db"
    }
    return $db
}

$RepoRoot = Resolve-FullPath $RepoRoot
$OutputDir = Resolve-FullPath $OutputDir
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Initialize-Uia
$script:ResolvedAppExe = Resolve-AppExe $AppExe

$scenarios = New-Object System.Collections.Generic.List[object]
$started = (Get-Date).ToUniversalTime().ToString('o')

$scenarios.Add((Invoke-RouteScenario -Id 'chat.executable.setup' -Route 'chat' -RequiredAutomationIds @(
    'chat.surface', 'chat.executable.setup', 'chat.executable.path', 'chat.executable.approve'
)))
$scenarios.Add((Invoke-RouteScenario -Id 'chat.executable.approve' -Route 'chat' -Action {
    param($Root, $ScenarioDir, $LocalAppData)
    $helper = New-HelperExe $ScenarioDir 'claude.exe'
    Set-UiaValue $Root 'chat.executable.path' $helper
    Invoke-Uia $Root 'chat.executable.approve'
    Start-Sleep -Milliseconds 500
    return [ordered]@{ approvedPath = $helper; observed = (Assert-UiaElement $Root 'chat.executable.summary') }
} -RequiredAutomationIds @('chat.surface', 'chat.executable.path', 'chat.executable.approve')))
$scenarios.Add((Invoke-RouteScenario -Id 'chat.executable.rotate' -Route 'chat' -Action {
    param($Root, $ScenarioDir, $LocalAppData)
    $first = New-HelperExe $ScenarioDir 'claude.exe'
    $second = New-HelperExe $ScenarioDir 'claude-rotated.exe'
    Set-UiaValue $Root 'chat.executable.path' $first
    Invoke-Uia $Root 'chat.executable.approve'
    Start-Sleep -Milliseconds 500
    Set-UiaValue $Root 'chat.executable.path' $second
    Invoke-Uia $Root 'chat.executable.rotate'
    Start-Sleep -Milliseconds 500
    return [ordered]@{ first = $first; rotated = $second; observed = (Assert-UiaElement $Root 'chat.executable.summary') }
} -RequiredAutomationIds @('chat.surface', 'chat.executable.path', 'chat.executable.approve')))
$scenarios.Add((Invoke-RouteScenario -Id 'chat.executable.remove' -Route 'chat' -Action {
    param($Root, $ScenarioDir, $LocalAppData)
    $helper = New-HelperExe $ScenarioDir 'claude.exe'
    Set-UiaValue $Root 'chat.executable.path' $helper
    Invoke-Uia $Root 'chat.executable.approve'
    Start-Sleep -Milliseconds 500
    Invoke-Uia $Root 'chat.executable.remove'
    Start-Sleep -Milliseconds 500
    return [ordered]@{ removedPath = $helper; observed = (Assert-UiaElement $Root 'chat.executable.setup') }
} -RequiredAutomationIds @('chat.surface', 'chat.executable.path', 'chat.executable.approve')))
$scenarios.Add((Invoke-RouteScenario -Id 'chat.executable.denial.unapproved' -Route 'chat' -RequiredAutomationIds @(
    'chat.surface', 'chat.executable.setup', 'chat.executable.setupTitle', 'chat.executable.setupMessage'
)))

foreach ($fault in @('missing', 'replaced')) {
    $profile = Join-Path $OutputDir "profiles\chat.executable.denial.$fault"
    $setup = Invoke-RouteScenario -Id "chat.executable.denial.$fault.setup" -Route 'chat' -ProfileRoot $profile -Action {
        param($Root, $ScenarioDir, $LocalAppData)
        $helper = New-HelperExe $ScenarioDir 'claude.exe'
        Set-UiaValue $Root 'chat.executable.path' $helper
        Invoke-Uia $Root 'chat.executable.approve'
        Start-Sleep -Milliseconds 500
        return [ordered]@{ approvedPath = $helper }
    }
    $setupAction = @($setup.actions | Where-Object { $_.action -eq 'scenarioAction' -and $_.status -eq 'captured' }) | Select-Object -First 1
    if ($null -eq $setupAction -or [string]::IsNullOrWhiteSpace($setupAction.result.approvedPath)) {
        throw "Failed to prepare executable denial scenario: $fault"
    }
    $helperPath = $setupAction.result.approvedPath
    if ($fault -eq 'missing') {
        Remove-Item -LiteralPath $helperPath -Force
    } else {
        Add-Content -LiteralPath $helperPath -Value 'mutation'
    }
    $scenarios.Add((Invoke-RouteScenario -Id "chat.executable.denial.$fault" -Route 'chat' -ProfileRoot $profile -RequiredAutomationIds @(
        'chat.surface', 'chat.executable.setup', 'chat.executable.setupTitle', 'chat.executable.setupMessage'
    )))
}

foreach ($kind in @('unavailable', 'corrupt', 'locked')) {
    $profile = Join-Path $OutputDir "profiles\chat.history.$kind"
    $lockStream = $null
    $prepare = {
        param($LocalAppData)
        $db = Initialize-ProfileStorage $LocalAppData
        if ($kind -eq 'unavailable') {
            $secretDir = Join-Path $LocalAppData 'OpenBurnBar\protected-secrets'
            if (Test-Path -LiteralPath $secretDir) {
                Remove-Item -LiteralPath $secretDir -Recurse -Force
            }
        } elseif ($kind -eq 'corrupt') {
            Set-Content -LiteralPath $db -Value 'not a sqlcipher database' -Encoding UTF8
        } elseif ($kind -eq 'locked') {
            $script:lockStream = [System.IO.File]::Open($db, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
    }.GetNewClosure()
    try {
        $scenarios.Add((Invoke-RouteScenario -Id "chat.history.$kind" -Route 'chat' -ProfileRoot $profile -PrepareProfile $prepare -RequiredAutomationIds @(
            'chat.surface', 'chat.history.degraded', 'chat.history.title', 'chat.history.message', 'chat.history.retry'
        )))
    }
    finally {
        if ($null -ne $script:lockStream) {
            $script:lockStream.Dispose()
            $script:lockStream = $null
        }
    }
}

$retryProfile = Join-Path $OutputDir 'profiles\chat.history.retry'
$scenarios.Add((Invoke-RouteScenario -Id 'chat.history.retry' -Route 'chat' -ProfileRoot $retryProfile -PrepareProfile {
    param($LocalAppData)
    $db = Initialize-ProfileStorage $LocalAppData
    Set-Content -LiteralPath $db -Value 'not a sqlcipher database' -Encoding UTF8
} -Action {
    param($Root, $ScenarioDir, $LocalAppData)
    Invoke-Uia $Root 'chat.history.retry'
    Start-Sleep -Milliseconds 500
    return [ordered]@{ invoked = 'chat.history.retry'; observed = (Assert-UiaElement $Root 'chat.history.degraded') }
} -RequiredAutomationIds @('chat.surface', 'chat.history.degraded', 'chat.history.retry')))

$restartProfile = Join-Path $OutputDir 'profiles\chat.restart'
$scenarios.Add((Invoke-RouteScenario -Id 'chat.restart.process' -Route 'chat' -ProfileRoot $restartProfile -Action {
    param($Root, $ScenarioDir, $LocalAppData)
    $helper = New-HelperExe $ScenarioDir 'claude.exe'
    Set-UiaValue $Root 'chat.executable.path' $helper
    Invoke-Uia $Root 'chat.executable.approve'
    Start-Sleep -Milliseconds 500
    Set-UiaValue $Root 'chat.input' 'durable restart marker'
    Start-Sleep -Milliseconds 250
    Invoke-Uia $Root 'chat.send'
    Start-Sleep -Milliseconds 1000
    return [ordered]@{ submitted = 'durable restart marker'; observed = (Assert-UiaElement $Root 'chat.messages') }
} -RequiredAutomationIds @('chat.surface', 'chat.executable.path', 'chat.input')))
$scenarios.Add((Invoke-RouteScenario -Id 'chat.restart.durable-rehydrate' -Route 'chat' -ProfileRoot $restartProfile -RequiredAutomationIds @(
    'chat.surface', 'chat.messages', 'chat.messageList'
)))
$scenarios.Add((Invoke-RouteScenario -Id 'chat.attachment.paste' -Route 'chat' -Action {
    param($Root, $ScenarioDir, $LocalAppData)
    [System.Windows.Forms.Clipboard]::SetText(('openburnbar paste attachment evidence ' * 512))
    $input = Find-ByAutomationId $Root 'chat.input'
    if ($null -eq $input) { throw 'UIA element not found: chat.input' }
    $input.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 1000
    return [ordered]@{ observed = (Assert-UiaElement $Root 'chat.attachments.pending') }
} -RequiredAutomationIds @('chat.surface', 'chat.input')))

$result = [ordered]@{
    schema = 'openburnbar.windows.foundation-interactive-uia.v1'
    startedAtUtc = $started
    completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    repoRoot = $RepoRoot
    appExe = $script:ResolvedAppExe
    actor = [ordered]@{
        identitySha256 = Get-StringSha256 ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
        sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        isSession0 = ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0)
    }
    scenarios = $scenarios
}

Write-JsonFile (Join-Path $OutputDir 'interactive-result.json') $result
if ($result.actor.isSession0) {
    exit 10
}
if (($scenarios | Where-Object { $_.status -ne 'captured' }).Count -gt 0) {
    exit 11
}
exit 0
