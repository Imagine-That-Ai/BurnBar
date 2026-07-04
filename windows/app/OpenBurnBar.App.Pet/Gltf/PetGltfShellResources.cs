using System;
using System.IO;

namespace OpenBurnBar.App.Pet.Gltf;

// MARK: - Bundled glTF shell resources
//
// The three.js pet shell (index.html) is embedded in this assembly. A concrete host
// (WebView2PetGltfHost) extracts it to a folder — alongside the dev-host-vendored
// three.js under vendor/ — and points the web view at it. Keeping the extraction
// here means the WinUI app never hard-codes resource names, and the shell is loaded
// + asserted on the macOS authoring host (windows/tests/pet) without a browser.
//
// Mirrors OpenBurnBar.Pretext.PretextShellResources.

/// Accessors for the embedded PetCompanion glTF shell.
public static class PetGltfShellResources
{
    /// Logical name of the three.js bridge shell (see the csproj LogicalName).
    public const string IndexHtmlResourceName = "petgltf.index.html";

    /// The WebView2 bridge `index.html` (three.js scene + JSON bridge).
    public static string ReadIndexHtml() => ReadText(IndexHtmlResourceName);

    /// Extract the shell into <paramref name="targetDirectory"/> (created if missing)
    /// and return the absolute path of the written `index.html`. The three.js vendor
    /// bundle must be populated under <c>{targetDirectory}/vendor/</c> by the dev-host
    /// build step (see Resources/PetGltf/vendor/README.md).
    public static string ExtractTo(string targetDirectory)
    {
        if (targetDirectory is null)
        {
            throw new ArgumentNullException(nameof(targetDirectory));
        }
        Directory.CreateDirectory(targetDirectory);
        var indexPath = Path.Combine(targetDirectory, "index.html");
        File.WriteAllText(indexPath, ReadIndexHtml());
        return indexPath;
    }

    private static string ReadText(string logicalName)
    {
        var assembly = typeof(PetGltfShellResources).Assembly;
        using var stream = assembly.GetManifestResourceStream(logicalName)
            ?? throw new InvalidOperationException(
                $"Embedded pet glTF resource '{logicalName}' not found. Available: {string.Join(", ", assembly.GetManifestResourceNames())}");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
