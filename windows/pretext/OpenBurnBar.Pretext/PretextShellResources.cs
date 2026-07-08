using System;
using System.IO;

namespace OpenBurnBar.Pretext;

// MARK: - Bundled shell resources
//
// The Pretext shell (index.html + pretext.bundle.min.js) is embedded in this
// assembly. A concrete host (e.g. WebView2) extracts the two files to a folder and
// points the web view at index.html. Keeping the extraction here means the WinUI
// app never hard-codes resource names and the byte-verbatim bundle is single-sourced.

/// Accessors for the embedded Pretext shell files.
public static class PretextShellResources
{
    /// Logical name of the byte-verbatim macOS bundle (see the csproj LogicalName).
    public const string BundleResourceName = "pretext.bundle.min.js";

    /// Logical name of the WebView2 bridge shell.
    public const string IndexHtmlResourceName = "pretext.index.html";

    /// The verbatim `pretext.bundle.min.js` layout engine.
    public static string ReadBundleJavaScript() => ReadText(BundleResourceName);

    /// The WebView2 bridge `index.html`.
    public static string ReadIndexHtml() => ReadText(IndexHtmlResourceName);

    /// Extract both shell files into <paramref name="targetDirectory"/> (created if
    /// missing) and return the absolute path of the written `index.html`. A WebView2
    /// host navigates to this path (or maps the folder as a virtual host).
    public static string ExtractTo(string targetDirectory)
    {
        if (targetDirectory is null)
        {
            throw new ArgumentNullException(nameof(targetDirectory));
        }
        Directory.CreateDirectory(targetDirectory);
        var bundlePath = Path.Combine(targetDirectory, "pretext.bundle.min.js");
        var indexPath = Path.Combine(targetDirectory, "index.html");
        File.WriteAllText(bundlePath, ReadBundleJavaScript());
        File.WriteAllText(indexPath, ReadIndexHtml());
        return indexPath;
    }

    private static string ReadText(string logicalName)
    {
        var assembly = typeof(PretextShellResources).Assembly;
        using var stream = assembly.GetManifestResourceStream(logicalName)
            ?? throw new InvalidOperationException(
                $"Embedded Pretext resource '{logicalName}' not found. Available: {string.Join(", ", assembly.GetManifestResourceNames())}");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
