[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedName,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedPublisher,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDisplayName,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedPublisherDisplayName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^\d+\.\d+\.\d+\.\d+$")]
    [string]$ExpectedVersion,

    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "arm64")]
    [string]$ExpectedArchitecture,

    [ValidateSet("Any", "Signed", "Unsigned")]
    [string]$SignatureExpectation = "Any",

    [ValidateSet("Sideload", "MicrosoftStore")]
    [string]$DistributionChannel = "Sideload",

    [string]$StoreProductId = "",

    [string]$MakeAppxPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$package = (Resolve-Path -LiteralPath $PackagePath).Path
if ([System.IO.Path]::GetExtension($package) -cne ".msix") {
    throw "PackagePath must end in .msix: $package"
}
if ($DistributionChannel -ceq "MicrosoftStore" -and -not $StoreProductId) {
    throw "StoreProductId is required when verifying a MicrosoftStore package."
}
if ($DistributionChannel -ceq "Sideload" -and $StoreProductId) {
    throw "StoreProductId is reserved for MicrosoftStore package verification."
}

if (-not $MakeAppxPath) {
    $MakeAppxPath = Get-ChildItem `
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makeappx.exe" `
        -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $MakeAppxPath -or -not (Test-Path -LiteralPath $MakeAppxPath -PathType Leaf)) {
    throw "MakeAppx.exe was not found. Pass -MakeAppxPath or install the Windows SDK."
}

$archive = [System.IO.Compression.ZipFile]::OpenRead($package)
try {
    $hasSignatureEntry = $null -ne (
        $archive.Entries |
            Where-Object { $_.FullName -ceq "AppxSignature.p7x" } |
            Select-Object -First 1
    )
}
finally {
    $archive.Dispose()
}

if ($SignatureExpectation -ceq "Signed") {
    if (-not $hasSignatureEntry) {
        throw "Expected AppxSignature.p7x in signed MSIX: $package"
    }
    $signature = Get-AuthenticodeSignature -FilePath $package
    if ($signature.Status -ne "Valid" -or -not $signature.SignerCertificate) {
        throw "Expected a valid Authenticode signature, got $($signature.Status): $package"
    }
}
elseif ($SignatureExpectation -ceq "Unsigned" -and $hasSignatureEntry) {
    throw "Microsoft Store submission package must not contain AppxSignature.p7x: $package"
}

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("openburnbar-msix-identity-" + [guid]::NewGuid().ToString("N"))
try {
    & $MakeAppxPath unpack /p $package /d $stage /o | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "MakeAppx unpack failed with exit code $LASTEXITCODE."
    }

    $manifestPath = Join-Path $stage "AppxManifest.xml"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Unpacked MSIX has no AppxManifest.xml: $package"
    }

    $document = [System.Xml.XmlDocument]::new()
    $document.Load($manifestPath)
    $root = $document.DocumentElement
    if ($null -eq $root) {
        throw "Unpacked AppxManifest.xml has no root element."
    }
    $namespaces = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
    $namespaces.AddNamespace("pkg", $root.NamespaceURI)

    $identity = $document.SelectSingleNode("/pkg:Package/pkg:Identity", $namespaces)
    $displayName = $document.SelectSingleNode(
        "/pkg:Package/pkg:Properties/pkg:DisplayName",
        $namespaces
    )
    $publisherDisplayName = $document.SelectSingleNode(
        "/pkg:Package/pkg:Properties/pkg:PublisherDisplayName",
        $namespaces
    )
    if ($null -eq $identity -or $null -eq $displayName -or $null -eq $publisherDisplayName) {
        throw "Unpacked AppxManifest.xml is missing required package identity fields."
    }

    $actual = [ordered]@{
        Name = $identity.GetAttribute("Name")
        Publisher = $identity.GetAttribute("Publisher")
        DisplayName = $displayName.InnerText
        PublisherDisplayName = $publisherDisplayName.InnerText
        Version = $identity.GetAttribute("Version")
        Architecture = $identity.GetAttribute("ProcessorArchitecture")
    }
    $expected = [ordered]@{
        Name = $ExpectedName
        Publisher = $ExpectedPublisher
        DisplayName = $ExpectedDisplayName
        PublisherDisplayName = $ExpectedPublisherDisplayName
        Version = $ExpectedVersion
        Architecture = $ExpectedArchitecture
    }
    foreach ($field in $expected.Keys) {
        if ($actual[$field] -cne $expected[$field]) {
            throw "MSIX $field is '$($actual[$field])', expected '$($expected[$field])': $package"
        }
    }

    $updatesDirectory = Join-Path $stage "Resources\Updates"
    $latestFeed = Join-Path $updatesDirectory "latest-windows.json"
    $pinnedUpdateKey = Join-Path $updatesDirectory "pinned-update-key.pub"
    $distributionMarker = Join-Path $updatesDirectory "distribution-channel.json"
    if ($DistributionChannel -ceq "MicrosoftStore") {
        foreach ($forbiddenDirectUpdateFile in @($latestFeed, $pinnedUpdateKey)) {
            if (Test-Path -LiteralPath $forbiddenDirectUpdateFile) {
                throw "MicrosoftStore package contains forbidden direct-update metadata: $forbiddenDirectUpdateFile"
            }
        }
        if (-not (Test-Path -LiteralPath $distributionMarker -PathType Leaf)) {
            throw "MicrosoftStore package is missing distribution-channel.json."
        }
        $distribution = Get-Content -LiteralPath $distributionMarker -Raw | ConvertFrom-Json
        if ($distribution.schemaVersion -ne 1 -or
            $distribution.channel -cne "microsoft-store" -or
            $distribution.productId -cne $StoreProductId) {
            throw "MicrosoftStore distribution metadata does not match the expected product."
        }
    }
    else {
        foreach ($requiredDirectUpdateFile in @($latestFeed, $pinnedUpdateKey)) {
            if (-not (Test-Path -LiteralPath $requiredDirectUpdateFile -PathType Leaf)) {
                throw "Sideload package is missing required direct-update metadata: $requiredDirectUpdateFile"
            }
        }
        if (Test-Path -LiteralPath $distributionMarker) {
            throw "Sideload package contains Microsoft Store distribution metadata."
        }
    }

    Write-Host "MSIX identity verified: $($actual.Name) :: $($actual.Architecture) :: $($actual.Version)"
    Write-Host "Package display name verified: $($actual.DisplayName)"
    Write-Host "Publisher verified: $($actual.Publisher)"
    Write-Host "Publisher display name verified: $($actual.PublisherDisplayName)"
    Write-Host "Signature state verified: $SignatureExpectation"
    Write-Host "Distribution channel verified: $DistributionChannel"
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
