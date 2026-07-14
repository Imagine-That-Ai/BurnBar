using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Presentation.Projects;
using OpenBurnBar.App.Presentation.SessionLogs;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.Storage;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace OpenBurnBar.App.Projects;

/// <summary>
/// Projects nav destination (IA-4). Groups sessions by project name and loads
/// Tree-sitter symbols when the signed parser is present in the package.
/// </summary>
public sealed partial class ProjectsPage : Page
{
    private readonly ProjectCodeRootSettingsViewModel _rootSettings =
        WindowsSettingsComposition.CreateProjectCodeRootSettingsViewModel();
    private bool _isReloading;
    private bool _isApplying;

    public ProjectsPage()
    {
        InitializeComponent();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ReloadAsync();
    }

    private async System.Threading.Tasks.Task<bool> ReloadAsync()
    {
        if (_isReloading)
        {
            return false;
        }

        _isReloading = true;
        RenderCommandState();
        RootInfoBar.IsOpen = false;
        try
        {
            _rootSettings.Load();
            RenderRootSelection();
            ISessionLogReadSource source = WindowsStorageDevHost.CreateSessionLogReadSource();
            ProjectCodeMemoryService? service = App.Current.ProjectCodeMemory;
            var viewModel = service is null
                ? new ProjectsListViewModel(source)
                : new ProjectsListViewModel(source, service);

            await viewModel.LoadAsync();
            StatusText.Text = viewModel.Status;
            DepthText.Text = service is null
                ? UnavailableDepthStatus()
                : viewModel.DepthDisclosure;
            ProjectList.ItemsSource = viewModel.Projects;
            CodeSymbolList.ItemsSource = viewModel.CodeSymbols;
            return true;
        }
        catch (Exception ex)
        {
            RootInfoBar.Message = ex.Message;
            RootInfoBar.Severity = InfoBarSeverity.Error;
            RootInfoBar.IsOpen = true;
            return false;
        }
        finally
        {
            _isReloading = false;
            RenderCommandState();
        }
    }

    private async void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        nint owner = App.Current.MainWindowHandle;
        if (owner == nint.Zero)
        {
            ShowRootError("The Projects window is not ready for folder selection.");
            return;
        }

        try
        {
            var picker = new FolderPicker
            {
                SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
                ViewMode = PickerViewMode.List,
            };
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, owner);
            StorageFolder? folder = await picker.PickSingleFolderAsync();
            if (folder is not null)
            {
                await ApplyRootAsync(folder.Path);
            }
        }
        catch (Exception ex)
        {
            ShowRootError("The folder picker could not open: " + ex.Message);
        }
    }

    private async void ClearFolder_Click(object sender, RoutedEventArgs e)
    {
        await ApplyRootSelectionAsync(null, "Indexed folder cleared.");
    }

    private System.Threading.Tasks.Task ApplyRootAsync(string rootPath) =>
        ApplyRootSelectionAsync(rootPath, "Project folder selected and indexing enabled.");

    private async System.Threading.Tasks.Task ApplyRootSelectionAsync(
        string? rootPath,
        string successMessage)
    {
        ProjectCodeRootSettingsSnapshot previousRoot =
            WindowsSettingsComposition.LoadProjectCodeRootSettings();
        GeneralSettingsSnapshot previousGeneral = WindowsGeneralSettingsComposition.Load();
        _isApplying = true;
        RenderCommandState();
        try
        {
            if (rootPath is null)
            {
                _rootSettings.Clear();
            }
            else
            {
                _rootSettings.SelectRoot(rootPath);
                if (!previousGeneral.IndexingEnabled)
                {
                    var generalSettings = new GeneralSettingsViewModel(
                        new WindowsGeneralSettingsStore(WindowsSettingsComposition.SharedPersistence));
                    generalSettings.IndexingEnabled = true;
                }
            }

            await App.Current.ReconfigureProjectCodeMemoryAsync();
            if (await ReloadAsync())
            {
                ShowRootMessage(successMessage, InfoBarSeverity.Success);
            }
        }
        catch (Exception ex)
        {
            try
            {
                WindowsSettingsComposition.SaveProjectCodeRootSettings(previousRoot);
                GeneralSettingsSnapshot currentGeneral = WindowsGeneralSettingsComposition.Load();
                if (currentGeneral.IndexingEnabled != previousGeneral.IndexingEnabled)
                {
                    var generalSettings = new GeneralSettingsViewModel(
                        new WindowsGeneralSettingsStore(WindowsSettingsComposition.SharedPersistence));
                    generalSettings.IndexingEnabled = previousGeneral.IndexingEnabled;
                }

                _rootSettings.Load();
                await ReloadAsync();
                ShowRootError(ex.Message);
                RenderRootSelection();
            }
            catch (Exception rollbackError)
            {
                ShowRootError(
                    ex.Message
                    + " The previous project-folder setting could not be restored: "
                    + rollbackError.Message);
            }
        }
        finally
        {
            _isApplying = false;
            RenderCommandState();
        }
    }

    private void RenderRootSelection()
    {
        ProjectRootPathText.Text = _rootSettings.DisplayPath;
        ProjectRootStatusText.Text = _rootSettings.Status;
        RenderCommandState();
    }

    private void ShowRootError(string message)
    {
        ShowRootMessage(message, InfoBarSeverity.Error);
    }

    private void ShowRootMessage(string message, InfoBarSeverity severity)
    {
        RootInfoBar.Message = message;
        RootInfoBar.Severity = severity;
        RootInfoBar.IsOpen = true;
    }

    private void RenderCommandState()
    {
        bool enabled = !_isReloading && !_isApplying;
        ChooseFolderButton.IsEnabled = enabled;
        ClearFolderButton.IsEnabled = enabled && _rootSettings.IsConfigured;
    }

    private string UnavailableDepthStatus()
    {
        if (!_rootSettings.IsConfigured)
        {
            return "Choose a project folder to index code symbols.";
        }

        if (!_rootSettings.IsAvailable)
        {
            return "The selected project folder is unavailable.";
        }

        GeneralSettingsSnapshot general = WindowsGeneralSettingsComposition.Load();
        return general.IndexingEnabled
            ? "Project Code indexing could not start. Review the error above or diagnostics."
            : "Code indexing is off in General settings.";
    }
}
