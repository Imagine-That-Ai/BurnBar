using System;
using System.Collections.Generic;
using System.IO;

namespace OpenBurnBar.Native;

/// <summary>
/// Production-path probe for native FFI library location + load readiness.
/// Resolves candidate MSVC/dylib paths via <see cref="NativeLibraryLocator"/> and
/// reports whether a loadable artifact is present. Portable unit tests exercise
/// resolution without requiring a Windows MSVC host.
/// </summary>
public static class NativeFfiLoopbackProbe
{
    /// <summary>
    /// Probe for a native library named <paramref name="libraryStem"/> (e.g. "burnbar_remote").
    /// Returns a structured result; never throws for missing files (fail-closed as NotFound).
    /// </summary>
    public static NativeFfiProbeResult Probe(string libraryStem, string? searchRoot = null)
    {
        if (string.IsNullOrWhiteSpace(libraryStem))
        {
            return NativeFfiProbeResult.Invalid("library_stem_required");
        }

        string fileName = NativeLibraryLocator.PlatformFileName(libraryStem);
        var candidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(searchRoot) && Path.IsPathRooted(searchRoot))
        {
            candidates.Add(Path.Combine(searchRoot, fileName));
        }

        foreach (string dir in NativeLibraryLocator.DefaultSearchDirectories())
        {
            candidates.Add(Path.Combine(dir, fileName));
        }

        foreach (string path in candidates)
        {
            if (File.Exists(path))
            {
                return NativeFfiProbeResult.Found(path);
            }
        }

        return NativeFfiProbeResult.NotFound(candidates);
    }
}

public sealed record NativeFfiProbeResult(
    bool IsFound,
    string? Path,
    string? Reason,
    IReadOnlyList<string> Candidates)
{
    public static NativeFfiProbeResult Found(string path) =>
        new(true, path, null, Array.Empty<string>());

    public static NativeFfiProbeResult NotFound(IReadOnlyList<string> candidates) =>
        new(false, null, "not_found", candidates);

    public static NativeFfiProbeResult Invalid(string reason) =>
        new(false, null, reason, Array.Empty<string>());
}
