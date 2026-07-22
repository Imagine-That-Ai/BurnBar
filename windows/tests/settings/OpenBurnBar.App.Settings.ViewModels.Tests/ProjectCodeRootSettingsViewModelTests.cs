using OpenBurnBar.App.Settings.ViewModels;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class ProjectCodeRootSettingsViewModelTests
{
    [Fact]
    public void SelectRoot_CanonicalizesAndPersistsExistingFolder()
    {
        string root = CreateTemporaryDirectory();
        try
        {
            var store = new InMemoryProjectCodeRootSettingsStore();
            var viewModel = new ProjectCodeRootSettingsViewModel(store);

            viewModel.SelectRoot(Path.Combine(root, "."));

            Assert.Equal(Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)), viewModel.RootPath);
            Assert.True(viewModel.IsConfigured);
            Assert.True(viewModel.IsAvailable);
            Assert.Equal(viewModel.RootPath, new ProjectCodeRootSettingsViewModel(store).RootPath);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void SelectRoot_RejectsMissingFolderAndFilesystemRoot()
    {
        var viewModel = new ProjectCodeRootSettingsViewModel();
        string missing = Path.Combine(Path.GetTempPath(), "openburnbar-missing-" + Guid.NewGuid().ToString("N"));

        Assert.Throws<ArgumentException>(() => viewModel.SelectRoot(missing));
        Assert.Throws<ArgumentException>(() => viewModel.SelectRoot(Path.GetPathRoot(Path.GetTempPath())!));
        Assert.False(viewModel.IsConfigured);
    }

    [Fact]
    public void Load_PreservesUnavailableSelectionForVisibleRecovery()
    {
        string root = CreateTemporaryDirectory();
        var store = new InMemoryProjectCodeRootSettingsStore(new ProjectCodeRootSettingsSnapshot(root));
        Directory.Delete(root, recursive: true);

        var viewModel = new ProjectCodeRootSettingsViewModel(store);

        Assert.Equal(Path.GetFullPath(root), viewModel.RootPath);
        Assert.True(viewModel.IsConfigured);
        Assert.False(viewModel.IsAvailable);
        Assert.Contains("unavailable", viewModel.Status, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Clear_RemovesPersistedSelection()
    {
        string root = CreateTemporaryDirectory();
        try
        {
            var store = new InMemoryProjectCodeRootSettingsStore(new ProjectCodeRootSettingsSnapshot(root));
            var viewModel = new ProjectCodeRootSettingsViewModel(store);

            viewModel.Clear();

            Assert.Null(viewModel.RootPath);
            Assert.Null(store.Load().RootPath);
            Assert.False(viewModel.IsConfigured);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void Load_DropsMalformedPersistedPath()
    {
        string malformed = new('x', ProjectCodeRootSettingsViewModel.MaxRootPathCharacters + 1);
        var store = new InMemoryProjectCodeRootSettingsStore(new ProjectCodeRootSettingsSnapshot(malformed));

        var viewModel = new ProjectCodeRootSettingsViewModel(store);

        Assert.Null(viewModel.RootPath);
        Assert.Null(store.Load().RootPath);
        Assert.False(viewModel.IsConfigured);
    }

    [Fact]
    public void SelectRoot_RejectsReparsePointFolder()
    {
        string target = CreateTemporaryDirectory();
        string link = target + "-link";
        try
        {
            try
            {
                Directory.CreateSymbolicLink(link, target);
            }
            catch (Exception error) when (
                error is IOException or UnauthorizedAccessException or PlatformNotSupportedException)
            {
                return;
            }

            var viewModel = new ProjectCodeRootSettingsViewModel();
            Assert.Throws<ArgumentException>(() => viewModel.SelectRoot(link));
            Assert.False(viewModel.IsConfigured);
        }
        finally
        {
            if (Directory.Exists(link))
            {
                Directory.Delete(link);
            }

            Directory.Delete(target, recursive: true);
        }
    }

    private static string CreateTemporaryDirectory()
    {
        string path = Path.Combine(Path.GetTempPath(), "openburnbar-project-root-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }
}
