using System;
using System.IO;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Durable non-secret selection for the active Project Code workspace.</summary>
public sealed record ProjectCodeRootSettingsSnapshot(string? RootPath)
{
    public static readonly ProjectCodeRootSettingsSnapshot Default = new((string?)null);
}

public interface IProjectCodeRootSettingsStore
{
    ProjectCodeRootSettingsSnapshot Load();

    void Save(ProjectCodeRootSettingsSnapshot settings);
}

public sealed class InMemoryProjectCodeRootSettingsStore : IProjectCodeRootSettingsStore
{
    private ProjectCodeRootSettingsSnapshot _settings;

    public InMemoryProjectCodeRootSettingsStore(ProjectCodeRootSettingsSnapshot? seed = null) =>
        _settings = seed ?? ProjectCodeRootSettingsSnapshot.Default;

    public ProjectCodeRootSettingsSnapshot Load() => _settings;

    public void Save(ProjectCodeRootSettingsSnapshot settings) => _settings = settings;
}

/// <summary>
/// Normalizes and persists the user-selected code folder. Selection rejects
/// volume roots and reparse-point roots so recursive indexing stays inside an
/// intentional, bounded workspace.
/// </summary>
public sealed class ProjectCodeRootSettingsViewModel : ObservableSettingsViewModel
{
    public const int MaxRootPathCharacters = 2048;

    private readonly IProjectCodeRootSettingsStore _store;
    private string? _rootPath;

    public ProjectCodeRootSettingsViewModel(IProjectCodeRootSettingsStore? store = null)
    {
        _store = store ?? new InMemoryProjectCodeRootSettingsStore();
        Load();
    }

    public string? RootPath => _rootPath;

    public bool IsConfigured => _rootPath is not null;

    public bool IsAvailable => _rootPath is not null && IsSafeExistingDirectory(_rootPath);

    public string DisplayPath => _rootPath ?? "No code folder selected";

    public string Status => _rootPath switch
    {
        null => "Choose a code folder to enable project symbols, references, and semantic search.",
        _ when !IsSafeExistingDirectory(_rootPath) => "The selected code folder is unavailable or no longer points to a regular folder. Choose it again or clear the selection.",
        _ => "Project Code indexing is configured for this folder.",
    };

    public void SelectRoot(string rootPath)
    {
        string normalized = Normalize(rootPath, requireExistingDirectory: true);
        if (Set(ref _rootPath, normalized, nameof(RootPath)))
        {
            Persist();
            RaiseDerived();
        }
    }

    public void Clear()
    {
        bool changed = Set(ref _rootPath, null, nameof(RootPath));
        Persist();
        if (changed)
        {
            RaiseDerived();
        }
    }

    public void Load()
    {
        string? stored = _store.Load().RootPath;
        try
        {
            _rootPath = string.IsNullOrWhiteSpace(stored)
                ? null
                : Normalize(stored, requireExistingDirectory: false);
        }
        catch (ArgumentException)
        {
            _rootPath = null;
            Persist();
        }

        OnPropertyChanged(nameof(RootPath));
        RaiseDerived();
    }

    private static string Normalize(string rootPath, bool requireExistingDirectory)
    {
        string trimmed = (rootPath ?? string.Empty).Trim();
        if (trimmed.Length == 0 || trimmed.Length > MaxRootPathCharacters)
        {
            throw new ArgumentException(
                $"The project folder path must contain between 1 and {MaxRootPathCharacters} characters.",
                nameof(rootPath));
        }

        string fullPath;
        try
        {
            fullPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(trimmed));
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new ArgumentException("The project folder path is invalid.", nameof(rootPath), error);
        }

        string? volumeRoot = Path.GetPathRoot(fullPath);
        if (string.IsNullOrWhiteSpace(volumeRoot)
            || string.Equals(
                Path.TrimEndingDirectorySeparator(volumeRoot),
                fullPath,
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
        {
            throw new ArgumentException("Choose a project folder, not an entire filesystem volume.", nameof(rootPath));
        }

        if (!requireExistingDirectory)
        {
            return fullPath;
        }

        if (!IsSafeExistingDirectory(fullPath))
        {
            throw new ArgumentException(
                "The selected project folder does not exist, cannot be inspected, or is a symbolic link or junction.",
                nameof(rootPath));
        }

        return fullPath;
    }

    private static bool IsSafeExistingDirectory(string path)
    {
        if (!Directory.Exists(path))
        {
            return false;
        }

        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private void Persist() => _store.Save(new ProjectCodeRootSettingsSnapshot(_rootPath));

    private void RaiseDerived()
    {
        OnPropertyChanged(nameof(IsConfigured));
        OnPropertyChanged(nameof(IsAvailable));
        OnPropertyChanged(nameof(DisplayPath));
        OnPropertyChanged(nameof(Status));
    }
}
