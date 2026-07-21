<#
.SYNOPSIS
    Publish one approved Windows safety fixture to isolated staging Remote Config.

.DESCRIPTION
    Derives the selected payload from a committed catalog, publishes only to
    burnbar-staging with ETag concurrency control, and verifies the returned
    parameters. The command emits no access token or public client value.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Baseline', 'ComputerKill', 'MediaKill', 'MalformedSystem')]
    [string] $Fixture,

    [switch] $ConfirmStagingMutation,

    [switch] $ValidateOnly,

    [ValidateSet('burnbar-staging')]
    [string] $ProjectId = 'burnbar-staging'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$httpModulePath = Join-Path $PSScriptRoot 'remote-config-http.psm1'
Import-Module -Name $httpModulePath -Force -Scope Local

if (-not $ValidateOnly -and -not $ConfirmStagingMutation) {
    throw 'Pass -ConfirmStagingMutation after confirming this is the isolated staging project.'
}
if ($ProjectId -cne 'burnbar-staging') {
    throw 'This helper is hard-bound to burnbar-staging and refuses every other project.'
}
$resolvedCatalogPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'remote-config-certification-fixtures.json')).Path
$catalogBytes = [System.IO.File]::ReadAllBytes($resolvedCatalogPath)
$catalogHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($catalogBytes)
).ToLowerInvariant()
$catalog = [Text.Encoding]::UTF8.GetString($catalogBytes) | ConvertFrom-Json
if ([string]$catalog.schema -cne 'openburnbar.windows.remote-config-certification-fixtures.v1') {
    throw 'Unsupported Remote Config certification fixture catalog schema.'
}
if ([string]$catalog.projectId -cne $ProjectId) {
    throw 'The Remote Config fixture catalog is not bound to burnbar-staging.'
}

$fixtureProperty = $catalog.fixtures.PSObject.Properties[$Fixture]
if ($null -eq $fixtureProperty) {
    throw "The requested Remote Config fixture is absent from the catalog: $Fixture"
}
$payloadObject = ($catalog.baseline | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
foreach ($override in $fixtureProperty.Value.overrides.PSObject.Properties) {
    $parameter = $payloadObject.parameters.PSObject.Properties[[string]$override.Name]
    if ($null -eq $parameter) {
        throw "Fixture $Fixture overrides an unknown Remote Config parameter: $($override.Name)"
    }
    $parameter.Value.defaultValue.value = [string]$override.Value
}
$valueTypeOverrides = $fixtureProperty.Value.PSObject.Properties['valueTypeOverrides']
if ($null -ne $valueTypeOverrides) {
    foreach ($override in $valueTypeOverrides.Value.PSObject.Properties) {
        $parameter = $payloadObject.parameters.PSObject.Properties[[string]$override.Name]
        if ($null -eq $parameter) {
            throw "Fixture $Fixture changes the type of an unknown Remote Config parameter: $($override.Name)"
        }
        $valueType = [string]$override.Value
        if (@('BOOLEAN', 'STRING') -cnotcontains $valueType) {
            throw "Fixture $Fixture uses an unsupported Remote Config valueType: $valueType"
        }
        $parameter.Value.valueType = $valueType
    }
}
$payload = $payloadObject | ConvertTo-Json -Depth 64
$payloadHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($payload))
).ToLowerInvariant()

if ($ValidateOnly) {
    $valueTypeOverrideNames = if ($null -eq $valueTypeOverrides) {
        @()
    } else {
        @($valueTypeOverrides.Value.PSObject.Properties.Name)
    }
    $overrideNames = @(
        @($fixtureProperty.Value.overrides.PSObject.Properties.Name) + $valueTypeOverrideNames |
            Sort-Object -Unique
    )
    $overriddenParameters = @($overrideNames | ForEach-Object {
        $parameter = $payloadObject.parameters.PSObject.Properties[[string]$_].Value
        $value = [string]$parameter.defaultValue.value
        [pscustomobject]@{
            name = [string]$_
            valueType = [string]$parameter.valueType
            valueSha256 = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($value))
            ).ToLowerInvariant()
        }
    })
    [pscustomobject]@{
        project = $ProjectId
        fixture = $Fixture
        catalogSha256 = $catalogHash
        fixturePayloadSha256 = $payloadHash
        payloadValidated = $true
        overriddenParameters = $overriddenParameters
        mutationAttempted = $false
    } | ConvertTo-Json -Depth 6
    return
}

$gcloud = Get-Command gcloud -ErrorAction SilentlyContinue
if ($null -eq $gcloud) {
    throw 'gcloud is required and must be authenticated as an approved staging operator.'
}

$activeProject = [string](& $gcloud.Source config get-value project 2>$null | Select-Object -First 1)
$activeProject = $activeProject.Trim()
if ($activeProject -cne $ProjectId) {
    throw "The active gcloud project is '$activeProject', not '$ProjectId'."
}

$token = $null
$httpClient = $null
try {
    $token = (& $gcloud.Source auth print-access-token 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'gcloud did not return an access token.'
    }

    $uri = "https://firebaseremoteconfig.googleapis.com/v1/projects/$ProjectId/remoteConfig"
    $httpClient = New-RemoteConfigHttpClient
    try {
        $current = Invoke-RemoteConfigRequest -Client $httpClient `
            -Method ([System.Net.Http.HttpMethod]::Get) -Uri $uri `
            -AccessToken $token -QuotaProject $ProjectId
    }
    catch {
        throw 'The staging Remote Config read failed. No mutation was attempted; inspect operator access without logging credentials.'
    }
    $etag = [string]$current.ETag
    if ([string]::IsNullOrWhiteSpace($etag)) {
        throw 'The current staging Remote Config response did not include an ETag.'
    }

    try {
        $published = Invoke-RemoteConfigRequest -Client $httpClient `
            -Method ([System.Net.Http.HttpMethod]::Put) -Uri $uri `
            -AccessToken $token -QuotaProject $ProjectId -IfMatch $etag -Body $payload
    }
    catch {
        throw 'The staging Remote Config publish failed. Verify and restore Baseline without logging credentials.'
    }

    function ConvertTo-CanonicalValue([object] $Value) {
        if ($null -eq $Value) { return $null }
        if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
        if ($Value -is [Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
                $result[$key] = ConvertTo-CanonicalValue $Value[$key]
            }
            return $result
        }
        if ($Value -is [Collections.IEnumerable]) {
            return @($Value | ForEach-Object { ConvertTo-CanonicalValue $_ })
        }
        $objectResult = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties.Name | Sort-Object)) {
            $objectResult[$property] = ConvertTo-CanonicalValue $Value.$property
        }
        return $objectResult
    }

    $live = $published.Content | ConvertFrom-Json
    $expectedParameters = (ConvertTo-CanonicalValue $payloadObject.parameters) | ConvertTo-Json -Depth 64 -Compress
    $liveParameters = (ConvertTo-CanonicalValue $live.parameters) | ConvertTo-Json -Depth 64 -Compress
    if ($expectedParameters -cne $liveParameters) {
        throw 'The live staging Remote Config parameters do not match the selected fixture.'
    }

    [pscustomobject]@{
        project = $ProjectId
        fixture = $Fixture
        catalogSha256 = $catalogHash
        fixturePayloadSha256 = $payloadHash
        statusCode = [int]$published.StatusCode
        parametersVerified = $true
        restoreRequired = ($Fixture -ne 'Baseline')
    } | ConvertTo-Json -Depth 4
}
finally {
    $token = $null
    if ($null -ne $httpClient) {
        $httpClient.Dispose()
    }
}
