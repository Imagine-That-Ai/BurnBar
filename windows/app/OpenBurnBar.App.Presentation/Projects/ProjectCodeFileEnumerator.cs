using System;
using System.Collections.Generic;
using System.IO;

namespace OpenBurnBar.App.Presentation.Projects;

/// <summary>
/// Deterministically walks a project tree without crossing directory or file
/// reparse points. This keeps project-code reads inside the selected workspace.
/// </summary>
internal static class ProjectCodeFileEnumerator
{
    public static IEnumerable<string> EnumerateCodeFiles(string root, int maxFiles)
    {
        if (maxFiles <= 0 || !TryNormalizeSafeDirectory(root, out string normalizedRoot))
        {
            yield break;
        }

        StringComparer comparer = OperatingSystem.IsWindows()
            ? StringComparer.OrdinalIgnoreCase
            : StringComparer.Ordinal;
        var pending = new Stack<string>();
        pending.Push(normalizedRoot);
        int count = 0;

        while (pending.Count > 0)
        {
            string directory = pending.Pop();
            if (!TryList(directory, directories: false, comparer, out string[] files)
                || !TryList(directory, directories: true, comparer, out string[] directories))
            {
                continue;
            }

            foreach (string path in files)
            {
                if (IsReparsePoint(path) || !ProjectCodeLexicalScanner.IsCodeFile(path))
                {
                    continue;
                }

                yield return path;
                if (++count >= maxFiles)
                {
                    yield break;
                }
            }

            for (int index = directories.Length - 1; index >= 0; index--)
            {
                string child = directories[index];
                if (!IsReparsePoint(child))
                {
                    pending.Push(child);
                }
            }
        }
    }

    public static bool IsSafeFileWithinRoot(string root, string path)
    {
        if (!TryNormalizeSafeDirectory(root, out string normalizedRoot))
        {
            return false;
        }

        try
        {
            string fullPath = Path.GetFullPath(path);
            StringComparison comparison = OperatingSystem.IsWindows()
                ? StringComparison.OrdinalIgnoreCase
                : StringComparison.Ordinal;
            string rootPrefix = normalizedRoot.EndsWith(Path.DirectorySeparatorChar)
                ? normalizedRoot
                : normalizedRoot + Path.DirectorySeparatorChar;
            if (!fullPath.StartsWith(rootPrefix, comparison))
            {
                return false;
            }

            string relativePath = Path.GetRelativePath(normalizedRoot, fullPath);
            string[] components = relativePath.Split(
                new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
                StringSplitOptions.RemoveEmptyEntries);
            if (components.Length == 0)
            {
                return false;
            }

            string current = normalizedRoot;
            for (int index = 0; index < components.Length - 1; index++)
            {
                current = Path.Combine(current, components[index]);
                if (!Directory.Exists(current) || IsReparsePoint(current))
                {
                    return false;
                }
            }

            return File.Exists(fullPath) && !IsReparsePoint(fullPath);
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private static bool TryNormalizeSafeDirectory(string root, out string normalizedRoot)
    {
        normalizedRoot = string.Empty;
        if (string.IsNullOrWhiteSpace(root))
        {
            return false;
        }

        try
        {
            normalizedRoot = Path.GetFullPath(root);
            return Directory.Exists(normalizedRoot) && !IsReparsePoint(normalizedRoot);
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private static bool TryList(
        string directory,
        bool directories,
        StringComparer comparer,
        out string[] entries)
    {
        try
        {
            entries = directories
                ? Directory.GetDirectories(directory)
                : Directory.GetFiles(directory);
            Array.Sort(entries, comparer);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            entries = Array.Empty<string>();
            return false;
        }
    }

    private static bool IsReparsePoint(string path)
    {
        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return true;
        }
    }
}
