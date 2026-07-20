Set-StrictMode -Version Latest

function Refresh-OpenBurnBarNativeEngineManifest {
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

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1) {
        throw "Unsupported native-engine manifest schema in ${manifestPath}: $($manifest.schemaVersion)"
    }

    foreach ($entry in @($manifest.files)) {
        $relative = [string]$entry.fileName
        if ([string]::IsNullOrWhiteSpace($relative)) {
            throw "Native-engine manifest contains an empty fileName: $manifestPath"
        }
        $normalized = $relative.Replace('\', '/')
        $segments = $normalized.Split('/')
        if ([System.IO.Path]::IsPathRooted($relative) -or ($segments -contains '..') -or ($segments -contains '')) {
            throw "Native-engine manifest contains an unsafe relative path '$relative'."
        }

        $candidate = Join-Path $resolvedRoot ($normalized.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Native-engine manifest file is missing from the packaged layout: $relative"
        }
        $entry.sizeBytes = [int64](Get-Item -LiteralPath $candidate).Length
        $entry.sha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    $temporaryPath = "$manifestPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
        Move-Item -LiteralPath $temporaryPath -Destination $manifestPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Native-engine manifest refreshed after signing: $manifestPath"
}
