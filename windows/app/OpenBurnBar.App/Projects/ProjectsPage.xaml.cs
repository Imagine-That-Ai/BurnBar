using System;
using System.IO;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Presentation.Projects;
using OpenBurnBar.App.Presentation.SessionLogs;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Storage;

namespace OpenBurnBar.App.Projects;

/// <summary>
/// Projects nav destination (IA-4). Groups sessions by project name and loads
/// Tree-sitter symbols when the signed parser is present in the package.
/// </summary>
public sealed partial class ProjectsPage : Page
{
    private ProjectCodeSymbolIndex? _codeIndex;

    public ProjectsPage()
    {
        InitializeComponent();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        ISessionLogReadSource source = WindowsStorageDevHost.CreateSessionLogReadSource();
        string? projectRoot = Environment.GetEnvironmentVariable("OPENBURNBAR_PROJECT_ROOT");
        _codeIndex?.Dispose();
        _codeIndex = null;
        IProjectCodeStaticParserClient? parser = null;
        bool indexingEnabled = WindowsGeneralSettingsComposition.Load().IndexingEnabled;
        if (indexingEnabled && !string.IsNullOrWhiteSpace(projectRoot) && Directory.Exists(projectRoot))
        {
            string? parserPath = Environment.GetEnvironmentVariable("OPENBURNBAR_CODE_STATIC_PARSER_PATH");
            if (string.IsNullOrWhiteSpace(parserPath))
            {
                string packagedPath = Path.Combine(
                    AppContext.BaseDirectory,
                    "ProjectCode",
                    "project-code-static-parser.exe");
                parserPath = File.Exists(packagedPath) ? packagedPath : null;
            }

            if (!string.IsNullOrWhiteSpace(parserPath) && File.Exists(parserPath))
            {
                parser = new JsonLinesProjectCodeStaticParserClient(parserPath);
            }

            ProjectCodeMemoryStore? store = TryCreateProjectCodeStore();
            _codeIndex = new ProjectCodeSymbolIndex(projectRoot, parser: parser, store: store);
            _codeIndex.StartWatching();
        }

        var viewModel = new ProjectsListViewModel(source, _codeIndex, parser);
        await viewModel.LoadAsync();
        StatusText.Text = viewModel.Status;
        DepthText.Text = viewModel.DepthDisclosure;
        ProjectList.ItemsSource = viewModel.Projects;
        CodeSymbolList.ItemsSource = viewModel.CodeSymbols;
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        _codeIndex?.Dispose();
        _codeIndex = null;
        base.OnNavigatedFrom(e);
    }

    private static ProjectCodeMemoryStore? TryCreateProjectCodeStore()
    {
        try
        {
            string storePath = Environment.GetEnvironmentVariable("OPENBURNBAR_PROJECT_MEMORY_PATH")
                ?? Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "OpenBurnBar",
                    "project-code-memory.sqlite");
            (_, string? passphrase) = WindowsStorageDevHost.ResolveCredentials();
            return new ProjectCodeMemoryStore(
                storePath,
                encryptionPassphrase: passphrase,
                embeddingProvider: ProjectCodeEmbeddingProviderComposition.TryCreate());
        }
        catch
        {
            // Projects remains usable through the bounded JSON/in-memory fallback
            // when protected storage is unavailable during navigation.
            return null;
        }
    }
}
