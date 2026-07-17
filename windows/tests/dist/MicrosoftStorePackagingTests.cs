using System;
using System.IO;
using System.Text.Json;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class MicrosoftStorePackagingTests
{
    private const string ProductId = "9PKMSDP99CJ6";
    private const string PackageName = "ImagineThatAiLLC.BurnBar";
    private const string Publisher = "CN=5AE4835A-8FC9-48CF-9453-81F465AD2216";
    private const string PublisherDisplayName = "Imagine That Ai LLC";
    private const string PackageFamilyName = "ImagineThatAiLLC.BurnBar_txkpd5gwvjf3t";

    [Fact]
    public void StoreIdentityMatchesTheReservedPartnerCenterProduct()
    {
        string root = DistTestSupport.RepositoryRoot();
        using JsonDocument document = JsonDocument.Parse(File.ReadAllText(Path.Combine(
            root,
            "windows",
            "packaging",
            "msix",
            "store-identity.json")));
        JsonElement identity = document.RootElement;

        Assert.Equal(1, identity.GetProperty("schemaVersion").GetInt32());
        Assert.Equal(ProductId, identity.GetProperty("productId").GetString());
        Assert.Equal("BurnBar", identity.GetProperty("productName").GetString());
        Assert.Equal(PackageName, identity.GetProperty("packageIdentityName").GetString());
        Assert.Equal(Publisher, identity.GetProperty("publisher").GetString());
        Assert.Equal(PublisherDisplayName, identity.GetProperty("publisherDisplayName").GetString());
        Assert.Equal(PackageFamilyName, identity.GetProperty("packageFamilyName").GetString());
        Assert.Equal(
            "S-1-15-2-3716396517-2214542516-22728229-3189976164-2645953789-3160967995-2035458168",
            identity.GetProperty("packageSid").GetString());
        Assert.Equal(
            "7b8e23a6-b790-4d4a-9f51-25d7dd0d7d9a",
            identity.GetProperty("msaAppId").GetString());
    }

    [Fact]
    public void MsixPackagerRequiresAndStampsTheCompleteStoreIdentity()
    {
        string root = DistTestSupport.RepositoryRoot();
        string packager = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "packaging",
            "msix",
            "New-MsixPackage.ps1"));

        Assert.Contains("[ValidateSet(\"Sideload\", \"MicrosoftStore\")]", packager, StringComparison.Ordinal);
        Assert.Contains("MicrosoftStore packaging requires a complete Partner Center identity", packager, StringComparison.Ordinal);
        Assert.Contains("SetAttribute(\"Name\", $PackageName)", packager, StringComparison.Ordinal);
        Assert.Contains("SetAttribute(\"Publisher\", $Publisher)", packager, StringComparison.Ordinal);
        Assert.Contains("$packageDisplayNameNode.InnerText = $PackageDisplayName", packager, StringComparison.Ordinal);
        Assert.Contains("$publisherDisplayNameNode.InnerText = $PublisherDisplayName", packager, StringComparison.Ordinal);
        Assert.Contains("StoreProductId", packager, StringComparison.Ordinal);
        Assert.Contains("distribution-channel.json", packager, StringComparison.Ordinal);
        Assert.Contains("Remove-Item -LiteralPath $latestFeed, $pinnedUpdateKey", packager, StringComparison.Ordinal);
        Assert.Contains("overrides are reserved for the MicrosoftStore channel", packager, StringComparison.Ordinal);
    }

    [Fact]
    public void ReleaseKeepsStorePackagesUnsignedAndOutsideDirectArtifactSigning()
    {
        string root = DistTestSupport.RepositoryRoot();
        string workflow = File.ReadAllText(Path.Combine(
            root,
            ".github",
            "workflows",
            "openburnbar-release-windows.yml"));

        int storeBuild = workflow.IndexOf(
            "- name: Build Microsoft Store MSIX packages",
            StringComparison.Ordinal);
        int directSigning = workflow.IndexOf(
            "- name: Authenticode sign the direct-download MSIX",
            StringComparison.Ordinal);
        int storeVerification = workflow.IndexOf(
            "- name: Verify Microsoft Store MSIX identity and unsigned state",
            StringComparison.Ordinal);

        Assert.True(storeBuild >= 0);
        Assert.True(directSigning > storeBuild);
        Assert.True(storeVerification > directSigning);
        Assert.Contains("artifacts/store/OpenBurnBar-${env:VERSION}-store-$arch.msix", workflow, StringComparison.Ordinal);
        Assert.Contains("-DistributionChannel MicrosoftStore", workflow, StringComparison.Ordinal);
        Assert.Contains("-PackageDisplayName $identity.productName", workflow, StringComparison.Ordinal);
        Assert.Contains("-StoreProductId $identity.productId", workflow, StringComparison.Ordinal);
        Assert.Contains("-SignatureExpectation Unsigned", workflow, StringComparison.Ordinal);
        Assert.Contains("files-folder: ${{ github.workspace }}/artifacts", workflow, StringComparison.Ordinal);
        Assert.Contains("files-folder-recurse: false", workflow, StringComparison.Ordinal);
        Assert.Contains("artifacts/store/*.msix", workflow, StringComparison.Ordinal);
        Assert.Contains("find artifacts -type f -print0", workflow, StringComparison.Ordinal);

        string pullRequestWorkflow = File.ReadAllText(Path.Combine(
            root,
            ".github",
            "workflows",
            "pr-windows-dist.yml"));
        Assert.Contains("name: Windows MSIX package identity smoke", pullRequestWorkflow, StringComparison.Ordinal);
        Assert.Contains("runs-on: windows-latest", pullRequestWorkflow, StringComparison.Ordinal);
        Assert.Contains("dotnet publish windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj", pullRequestWorkflow, StringComparison.Ordinal);
        Assert.Contains("-DistributionChannel Sideload", pullRequestWorkflow, StringComparison.Ordinal);
        Assert.Contains("-DistributionChannel MicrosoftStore", pullRequestWorkflow, StringComparison.Ordinal);
        Assert.Contains("Test-MsixPackageIdentity.ps1", pullRequestWorkflow, StringComparison.Ordinal);
    }

    [Fact]
    public void StoreChannelCannotUseTheDirectDownloadUpdater()
    {
        string root = DistTestSupport.RepositoryRoot();
        string verifier = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "packaging",
            "msix",
            "Test-MsixPackageIdentity.ps1"));
        string updateService = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "Settings",
            "WindowsUpdateService.cs"));

        Assert.Contains("MicrosoftStore package contains forbidden direct-update metadata", verifier, StringComparison.Ordinal);
        Assert.Contains("Sideload package is missing required direct-update metadata", verifier, StringComparison.Ordinal);
        Assert.Contains("distribution.productId -cne $StoreProductId", verifier, StringComparison.Ordinal);
        Assert.Contains("DistributionKind.MicrosoftStore", updateService, StringComparison.Ordinal);
        Assert.Contains("ms-windows-store://downloadsandupdates", updateService, StringComparison.Ordinal);
        Assert.Contains("ms-windows-store://pdp/?productid=", updateService, StringComparison.Ordinal);
        Assert.Contains("Microsoft Store manages signing, installation, and automatic updates", updateService, StringComparison.Ordinal);
        Assert.Contains("Updater disabled: packaged distribution metadata is malformed.", updateService, StringComparison.Ordinal);
    }

    [Fact]
    public void V1035PrivateSubmissionRunbookIsBoundToTheExactStoreCandidate()
    {
        string root = DistTestSupport.RepositoryRoot();
        string evidenceRoot = Path.Combine(
            root,
            "docs",
            "windows-port",
            "evidence",
            "windows-v1.0.35-release");
        string runbook = File.ReadAllText(Path.Combine(
            evidenceRoot,
            "STORE_PRIVATE_SUBMISSION_RUNBOOK.md"));
        using JsonDocument packet = JsonDocument.Parse(File.ReadAllText(Path.Combine(
            evidenceRoot,
            "exact-signed-artifacts-2cfa9db885.json")));

        JsonElement source = packet.RootElement.GetProperty("source");
        Assert.Equal("1.0.35", source.GetProperty("version").GetString());
        Assert.Equal(
            "2cfa9db885dafef7f1f451a9e05a8ee775351d44",
            source.GetProperty("mergeCommitSha").GetString());
        Assert.Contains(source.GetProperty("mergeCommitSha").GetString()!, runbook, StringComparison.Ordinal);
        Assert.Contains(ProductId, runbook, StringComparison.Ordinal);
        Assert.Contains(PackageName, runbook, StringComparison.Ordinal);
        Assert.Contains(Publisher, runbook, StringComparison.Ordinal);
        Assert.Contains(PublisherDisplayName, runbook, StringComparison.Ordinal);
        Assert.Contains(PackageFamilyName, runbook, StringComparison.Ordinal);
        Assert.Contains("**Private audience**", runbook, StringComparison.Ordinal);
        Assert.Contains("https://burnbar.ai/legal/privacy-policy", runbook, StringComparison.Ordinal);
        Assert.Contains("https://burnbar.ai/support", runbook, StringComparison.Ordinal);

        JsonElement distributionObjects = packet.RootElement.GetProperty("distributionObjects");
        int storePackageCount = 0;
        foreach (JsonElement item in distributionObjects.EnumerateArray())
        {
            if (item.GetProperty("channel").GetString() != "microsoft-store")
            {
                continue;
            }

            storePackageCount += 1;
            Assert.Contains(item.GetProperty("fileName").GetString()!, runbook, StringComparison.Ordinal);
            Assert.Contains(item.GetProperty("sha256").GetString()!, runbook, StringComparison.Ordinal);
            Assert.Contains(item.GetProperty("sizeBytes").GetInt64().ToString(), runbook, StringComparison.Ordinal);
        }

        Assert.Equal(2, storePackageCount);

        string privacyPolicy = File.ReadAllText(Path.Combine(
            root,
            "website",
            "src",
            "pages",
            "legal",
            "privacy-policy.astro"));
        string support = File.ReadAllText(Path.Combine(
            root,
            "website",
            "src",
            "pages",
            "support.astro"));
        Assert.Contains("DPAPI-protected Windows", privacyPolicy, StringComparison.Ordinal);
        Assert.Contains("Microsoft Store", privacyPolicy, StringComparison.Ordinal);
        Assert.Contains("Windows", support, StringComparison.Ordinal);
        Assert.Contains("Microsoft Store", support, StringComparison.Ordinal);
    }
}
