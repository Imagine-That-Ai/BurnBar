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
    [string]$MakePriPath = "",
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
if (-not $MakePriPath) {
    $MakePriPath = Get-ChildItem `
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makepri.exe" `
        -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $MakePriPath -or -not (Test-Path -LiteralPath $MakePriPath -PathType Leaf)) {
    throw "MakePri.exe was not found. Pass -MakePriPath or install the Windows SDK."
}

$output = [System.IO.Path]::GetFullPath($OutputPath)
if ([System.IO.Path]::GetExtension($output) -ne ".msix") {
    throw "OutputPath must end in .msix: $output"
}
$outputDirectory = Split-Path -Parent $output
[void](New-Item -ItemType Directory -Path $outputDirectory -Force)

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("openburnbar-msix-" + [guid]::NewGuid().ToString("N"))
$priWork = Join-Path ([System.IO.Path]::GetTempPath()) ("openburnbar-pri-" + [guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $stage)
[void](New-Item -ItemType Directory -Path $priWork)

try {
    Copy-Item -Path (Join-Path $publish "*") -Destination $stage -Recurse -Force
    Copy-Item -LiteralPath $imagesSource -Destination (Join-Path $stage "Images") -Recurse -Force

    $document = [System.Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $false
    $document.Load($manifestSource)
    $package = $document.DocumentElement
    if ($null -eq $package) {
        throw "Package.appxmanifest has no root element."
    }
    $namespaces = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
    $namespaces.AddNamespace("pkg", $package.NamespaceURI)
    $identity = $document.SelectSingleNode("/pkg:Package/pkg:Identity", $namespaces)
    if ($null -eq $identity) {
        throw "Package.appxmanifest has no Identity element."
    }
    $identity.SetAttribute("Version", "$Version.0")
    $identity.SetAttribute("ProcessorArchitecture", $Architecture)
    if ($Publisher) {
        $identity.SetAttribute("Publisher", $Publisher)
    }

    $application = $document.SelectSingleNode("/pkg:Package/pkg:Applications/pkg:Application", $namespaces)
    $executableAttribute = if ($null -eq $application) { $null } else { $application.Attributes["Executable"] }
    $executable = if ($null -eq $executableAttribute) { "" } else { $executableAttribute.Value }
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

    # dotnet publish emits a component PRI because the app is also shipped unpackaged.
    # MSIX activation requires those component maps to be merged into a package-root
    # resources.pri whose primary map matches the package identity.
    $resourcesPri = Join-Path $stage "resources.pri"
    Remove-Item -LiteralPath $resourcesPri -Force -ErrorAction SilentlyContinue
    $inputPris = @(Get-ChildItem -LiteralPath $stage -Recurse -Filter "*.pri" -File |
        Where-Object { $_.FullName -cne $resourcesPri } |
        Sort-Object FullName)
    $appPri = $inputPris | Where-Object { $_.Name -ceq "OpenBurnBar.App.pri" } | Select-Object -First 1
    if (-not $appPri) {
        throw "Publish output is missing OpenBurnBar.App.pri; packaged XAML cannot be indexed."
    }

    $priResfiles = Join-Path $stage "pri.resfiles"
    [System.IO.File]::WriteAllLines(
        $priResfiles,
        [string[]]@($inputPris.FullName),
        [System.Text.UTF8Encoding]::new($false)
    )

    $priConfig = Join-Path $priWork "priconfig.xml"
    & $MakePriPath createconfig /cf $priConfig /dq en-US /o | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "MakePri createconfig failed with exit code $LASTEXITCODE."
    }

    $priDocument = [System.Xml.XmlDocument]::new()
    $priDocument.PreserveWhitespace = $false
    $priDocument.Load($priConfig)
    $packaging = $priDocument.SelectSingleNode("/resources/packaging")
    if ($packaging) {
        [void]$packaging.ParentNode.RemoveChild($packaging)
    }
    $index = $priDocument.SelectSingleNode("/resources/index")
    if (-not $index) {
        throw "Generated MakePri configuration has no index element."
    }
    $index.SetAttribute("root", "\")
    $index.SetAttribute("startIndexAt", "pri.resfiles")
    foreach ($indexer in @($index.SelectNodes("indexer-config"))) {
        [void]$index.RemoveChild($indexer)
    }
    foreach ($type in @("PRI", "RESFILES")) {
        $indexer = $priDocument.CreateElement("indexer-config")
        $indexer.SetAttribute("type", $type)
        if ($type -ceq "RESFILES") {
            $indexer.SetAttribute("qualifierDelimiter", ".")
        }
        [void]$index.AppendChild($indexer)
    }
    $priDocument.Save($priConfig)

    $packageName = $identity.GetAttribute("Name")
    if (-not $packageName) {
        throw "Package.appxmanifest Identity is missing its Name attribute."
    }
    & $MakePriPath new /pr $stage /cf $priConfig /of $resourcesPri /in $packageName /o | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "MakePri new failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $resourcesPri -PathType Leaf)) {
        throw "MakePri completed without producing $resourcesPri."
    }

    $priDump = Join-Path $priWork "resources.pri.xml"
    & $MakePriPath dump /if $resourcesPri /of $priDump /dt detailed /o | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "MakePri dump failed with exit code $LASTEXITCODE."
    }
    $dumpDocument = [System.Xml.XmlDocument]::new()
    $dumpDocument.Load($priDump)
    $primaryMap = $dumpDocument.SelectSingleNode("/PriInfo/ResourceMap[@primary='true']")
    if (-not $primaryMap -or $primaryMap.GetAttribute("name") -cne $packageName) {
        $actualMap = if ($primaryMap) { $primaryMap.GetAttribute("name") } else { "<missing>" }
        throw "resources.pri primary map is '$actualMap', expected '$packageName'."
    }
    $flyoutXbf = $dumpDocument.SelectSingleNode("//NamedResource[@name='FlyoutWindow.xbf']")
    if (-not $flyoutXbf) {
        throw "resources.pri does not contain FlyoutWindow.xbf."
    }
    Remove-Item -LiteralPath $priResfiles -Force

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
    Write-Host "Package resource map: $packageName ($($inputPris.Count) component PRI files)"
    Write-Host "SHA-256: $hash"
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    if (Test-Path -LiteralPath $priWork) {
        Remove-Item -LiteralPath $priWork -Recurse -Force
    }
}
