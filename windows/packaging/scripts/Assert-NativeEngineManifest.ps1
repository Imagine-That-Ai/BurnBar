Set-StrictMode -Version Latest

function Assert-OpenBurnBarNativeEngineManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    $manifestPath = Join-Path $resolvedRoot "native-engine-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Native-engine manifest is missing from $resolvedRoot."
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        throw "Native-engine manifest is not valid JSON: $manifestPath :: $($_.Exception.Message)"
    }

    if ([int]$manifest.schemaVersion -ne 1) {
        throw "Unsupported native-engine manifest schema in ${manifestPath}: $($manifest.schemaVersion)"
    }
    $engineName = [string]$manifest.engine
    if ([string]::IsNullOrWhiteSpace($engineName)) {
        throw "Native-engine manifest does not declare an engine: $manifestPath"
    }

    $entries = @($manifest.files)
    if ($entries.Count -eq 0) {
        throw "Native-engine manifest contains no files: $manifestPath"
    }

    $seen = @{}
    foreach ($entry in $entries) {
        $relative = [string]$entry.fileName
        if ([string]::IsNullOrWhiteSpace($relative)) {
            throw "Native-engine manifest contains an empty fileName: $manifestPath"
        }
        $normalized = $relative.Replace('\', '/')
        $segments = $normalized.Split('/')
        if ([System.IO.Path]::IsPathRooted($relative) -or ($segments -contains '..') -or ($segments -contains '')) {
            throw "Native-engine manifest contains an unsafe relative path '$relative'."
        }
        $key = $normalized.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            throw "Native-engine manifest contains duplicate fileName '$relative'."
        }
        $seen[$key] = $true

        $candidate = Join-Path $resolvedRoot ($normalized.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Native-engine manifest file is missing from the packaged layout: $relative"
        }
        $actualSize = (Get-Item -LiteralPath $candidate).Length
        if ([int64]$entry.sizeBytes -ne $actualSize) {
            throw "Native-engine manifest size mismatch for ${relative}: expected $($entry.sizeBytes), got $actualSize"
        }
        $actualHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne ([string]$entry.sha256).ToLowerInvariant()) {
            throw "Native-engine manifest SHA-256 mismatch for ${relative}: expected $($entry.sha256), got $actualHash"
        }
    }

    if (-not ($seen.ContainsKey($engineName.ToLowerInvariant()))) {
        throw "Native-engine manifest does not hash its declared engine '$engineName'."
    }

    $bundleName = "OpenBurnBarCore_OpenBurnBarCore.resources"
    $bundlePath = Join-Path $resolvedRoot $bundleName
    if (-not (Test-Path -LiteralPath $bundlePath -PathType Container)) {
        throw "Required Swift resource bundle is missing from the packaged layout: $bundleName"
    }
    $bundlePrefix = "$($bundleName.ToLowerInvariant())/"
    if (-not ($seen.Keys | Where-Object { $_.StartsWith($bundlePrefix, [System.StringComparison]::Ordinal) })) {
        throw "Native-engine manifest does not hash any files from $bundleName."
    }

    Write-Host "Native-engine manifest verified: $($entries.Count) files; engine $engineName; resources $bundleName"
}
