[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDir,

    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "arm64")]
    [string]$Architecture,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^\d+\.\d+\.\d+$")]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$MakeAppxPath = "",
    [string]$Publisher = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$publish = (Resolve-Path -LiteralPath $PublishDir).Path
$manifestSource = Join-Path $scriptRoot "Package.appxmanifest"
$imagesSource = Join-Path $scriptRoot "Images"

if (-not (Test-Path -LiteralPath $manifestSource -PathType Leaf)) {
    throw "MSIX manifest not found at $manifestSource."
}
if (-not (Test-Path -LiteralPath $imagesSource -PathType Container)) {
    throw "MSIX images directory not found at $imagesSource."
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

$output = [System.IO.Path]::GetFullPath($OutputPath)
if ([System.IO.Path]::GetExtension($output) -ne ".msix") {
    throw "OutputPath must end in .msix: $output"
}
$outputDirectory = Split-Path -Parent $output
[void](New-Item -ItemType Directory -Path $outputDirectory -Force)

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("openburnbar-msix-" + [guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $stage)

try {
    Copy-Item -Path (Join-Path $publish "*") -Destination $stage -Recurse -Force
    Copy-Item -LiteralPath $imagesSource -Destination (Join-Path $stage "Images") -Recurse -Force

    $document = [System.Xml.Linq.XDocument]::Load($manifestSource)
    $package = $document.Root
    if ($null -eq $package) {
        throw "Package.appxmanifest has no root element."
    }
    $identity = $package.Element($package.Name.Namespace + "Identity")
    if ($null -eq $identity) {
        throw "Package.appxmanifest has no Identity element."
    }
    $identity.SetAttributeValue("Version", "$Version.0")
    $identity.SetAttributeValue("ProcessorArchitecture", $Architecture)
    if ($Publisher) {
        $identity.SetAttributeValue("Publisher", $Publisher)
    }

    $application = $package.Descendants($package.Name.Namespace + "Application") | Select-Object -First 1
    $executable = if ($null -eq $application) { "" } else { [string]$application.Attribute("Executable") }
    if (-not $executable -or -not (Test-Path -LiteralPath (Join-Path $stage $executable) -PathType Leaf)) {
        throw "Manifest executable '$executable' is missing from publish output $publish."
    }

    $manifestOutput = Join-Path $stage "AppxManifest.xml"
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($manifestOutput, $settings)
    try {
        $document.Save($writer)
    }
    finally {
        $writer.Dispose()
    }

    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Force
    }
    & $MakeAppxPath pack /d $stage /p $output /o /h SHA256
    if ($LASTEXITCODE -ne 0) {
        throw "MakeAppx failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw "MakeAppx completed without producing $output."
    }

    $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "MSIX created: $output"
    Write-Host "Architecture: $Architecture"
    Write-Host "Version: $Version.0"
    Write-Host "SHA-256: $hash"
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
