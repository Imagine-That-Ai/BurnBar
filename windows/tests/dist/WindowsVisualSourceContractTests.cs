using System;
using System.IO;
using System.Linq;
using System.Xml.Linq;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class WindowsVisualSourceContractTests
{
    [Fact]
    public void GradientStopsNeverReferenceBrushResourcesAsColors()
    {
        string appRoot = Path.Combine(
            DistTestSupport.RepositoryRoot(),
            "windows",
            "app",
            "OpenBurnBar.App");
        XNamespace presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
        var violations = Directory
            .EnumerateFiles(appRoot, "*.xaml", SearchOption.AllDirectories)
            .SelectMany(path => XDocument.Load(path)
                .Descendants(presentation + "GradientStop")
                .Select(element => new
                {
                    Path = path,
                    Color = (string?)element.Attribute("Color"),
                }))
            .Where(item => item.Color?.EndsWith("Brush}", StringComparison.Ordinal) == true)
            .Select(item => $"{Path.GetRelativePath(appRoot, item.Path)}: {item.Color}")
            .ToArray();
        XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        XDocument shell = XDocument.Load(Path.Combine(appRoot, "Theme", "PensieveShell.xaml"));
        string[] themeColorKeys =
        [
            "AuroraGlassSelectionFillColor",
            "AuroraGlassTintSunkenColor",
            "AuroraGlassSheenFromColor",
            "AuroraGlassSheenToColor",
            "AuroraGlassEdgeColor",
            "AuroraGlassEdgeBorderColor",
        ];

        Assert.Empty(violations);
        foreach (string key in themeColorKeys)
        {
            XElement[] aliases = shell
                .Descendants(presentation + "Color")
                .Where(element => string.Equals(
                    (string?)element.Attribute(xaml + "Key"),
                    key,
                    StringComparison.Ordinal))
                .ToArray();

            Assert.Equal(3, aliases.Length);
            Assert.All(aliases, alias => Assert.Matches("^#[0-9A-Fa-f]{8}$", alias.Value.Trim()));
        }
    }

    [Fact]
    public void AuroraDialogStylePreservesTheWinUiContentDialogTemplate()
    {
        string root = DistTestSupport.RepositoryRoot();
        XDocument controls = XDocument.Load(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "Theme",
            "GlassControls.xaml"));
        XNamespace presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
        XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        XElement style = controls
            .Descendants(presentation + "Style")
            .Single(element => string.Equals(
                (string?)element.Attribute(xaml + "Key"),
                "AuroraGlassDialogStyle",
                StringComparison.Ordinal));

        Assert.Equal("ContentDialog", (string?)style.Attribute("TargetType"));
        Assert.Equal(
            "{StaticResource DefaultContentDialogStyle}",
            (string?)style.Attribute("BasedOn"));
    }

    [Fact]
    public void ProgrammaticTopTabsUseTheWinUiAttachedPropertySetter()
    {
        string root = DistTestSupport.RepositoryRoot();
        string shell = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "Shell",
            "AppShell.xaml.cs"));

        Assert.Contains("ToolTipService.SetToolTip(button,", shell, StringComparison.Ordinal);
        Assert.DoesNotContain("ToolTipService.ToolTip =", shell, StringComparison.Ordinal);
    }

    [Fact]
    public void GlobalBrandFontIsInheritedFromAWinUiControlRatherThanGrid()
    {
        string root = DistTestSupport.RepositoryRoot();
        XNamespace presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
        XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        XDocument mainWindow = XDocument.Load(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "MainWindow.xaml"));
        XElement rootGrid = mainWindow
            .Descendants(presentation + "Grid")
            .Single(element => string.Equals(
                (string?)element.Attribute(xaml + "Name"),
                "RootGrid",
                StringComparison.Ordinal));
        XDocument shell = XDocument.Load(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "Shell",
            "AppShell.xaml"));

        Assert.Null(rootGrid.Attribute("FontFamily"));
        Assert.Equal(
            "{StaticResource AuroraBodyFont}",
            (string?)shell.Root?.Attribute("FontFamily"));
        Assert.Null(shell.Root?.Attribute("RequestedTheme"));
    }

    [Fact]
    public void PackagedBrandFontsCarryTheirLicenseNotice()
    {
        string root = DistTestSupport.RepositoryRoot();
        XDocument project = XDocument.Load(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "OpenBurnBar.App.csproj"));
        XElement license = project
            .Descendants("Content")
            .Single(element => string.Equals(
                (string?)element.Attribute("Include"),
                @"Assets\Fonts\LICENSE-fonts.txt",
                StringComparison.Ordinal));

        Assert.Equal("PreserveNewest", (string?)license.Attribute("CopyToOutputDirectory"));
        Assert.Equal("PreserveNewest", (string?)license.Attribute("CopyToPublishDirectory"));
    }

    [Fact]
    public void OutfitDisplayFontDefaultsToARealRegularWeight()
    {
        string path = Path.Combine(
            DistTestSupport.RepositoryRoot(),
            "windows",
            "app",
            "OpenBurnBar.App",
            "Assets",
            "Fonts",
            "outfit.ttf");
        byte[] font = File.ReadAllBytes(path);
        ushort tableCount = ReadUInt16BigEndian(font, 4);
        int os2Offset = -1;
        for (int index = 0; index < tableCount; index++)
        {
            int record = 12 + (index * 16);
            if (font[record] == (byte)'O' && font[record + 1] == (byte)'S' &&
                font[record + 2] == (byte)'/' && font[record + 3] == (byte)'2')
            {
                os2Offset = checked((int)ReadUInt32BigEndian(font, record + 8));
                break;
            }
        }

        Assert.True(os2Offset >= 0, "Outfit font is missing its OS/2 metadata table.");
        Assert.InRange(ReadUInt16BigEndian(font, os2Offset + 4), 400, 700);
    }

    [Fact]
    public void CodeBuiltAuroraSurfacesUseThemeResourceProbesAndRefreshOnThemeChange()
    {
        string root = DistTestSupport.RepositoryRoot();
        string dashboard = File.ReadAllText(Path.Combine(
            root, "windows", "app", "OpenBurnBar.App", "Dashboard", "DashboardCommandSidebar.xaml.cs"))
            .ReplaceLineEndings("\n");
        string bubble = File.ReadAllText(Path.Combine(
            root, "windows", "app", "OpenBurnBar.App", "Chat", "StreamingBubble.xaml.cs"))
            .ReplaceLineEndings("\n");

        Assert.Contains("InitializeComponent();\n        ApplyModeChrome();", dashboard, StringComparison.Ordinal);
        Assert.Contains("ActualThemeChanged += OnActualThemeChanged;", dashboard, StringComparison.Ordinal);
        Assert.Contains("AuroraTextBrushProbe.Background", dashboard, StringComparison.Ordinal);
        Assert.DoesNotContain("Resources.TryGetValue", dashboard, StringComparison.Ordinal);
        Assert.Contains("ActualThemeChanged += OnActualThemeChanged;", bubble, StringComparison.Ordinal);
        Assert.Contains("AuroraTextBrushProbe.Background", bubble, StringComparison.Ordinal);
        Assert.DoesNotContain("Resources.TryGetValue", bubble, StringComparison.Ordinal);
    }

    [Fact]
    public void PretextStagesAndLoadsTheBundledProductionFontsBeforeReadiness()
    {
        string root = DistTestSupport.RepositoryRoot();
        string host = File.ReadAllText(Path.Combine(
            root, "windows", "app", "OpenBurnBar.App", "Pretext", "WebView2PretextHost.cs"));
        string html = File.ReadAllText(Path.Combine(
            root, "windows", "pretext", "OpenBurnBar.Pretext", "Resources", "Pretext", "index.html"));

        Assert.Contains("StageBundledFonts();", host, StringComparison.Ordinal);
        Assert.Contains("\"geist.ttf\", \"jetbrains-mono.ttf\"", host, StringComparison.Ordinal);
        Assert.Contains("url(\"fonts/geist.ttf\")", html, StringComparison.Ordinal);
        Assert.Contains("url(\"fonts/jetbrains-mono.ttf\")", html, StringComparison.Ordinal);
        Assert.True(
            html.IndexOf("document.fonts.load", StringComparison.Ordinal) <
            html.IndexOf("value: { ready: true }", StringComparison.Ordinal),
            "Pretext must load bundled fonts before sending the ready heartbeat.");
    }

    [Fact]
    public void DashboardBackdropsUseXamlSafeCompositionSurfaces()
    {
        string root = DistTestSupport.RepositoryRoot();
        string kernel = File.ReadAllText(Path.Combine(
            root, "windows", "app", "OpenBurnBar.App", "Dashboard", "KernelBackdropHost.cs"));
        string swarm = File.ReadAllText(Path.Combine(
            root, "windows", "app", "OpenBurnBar.App", "Particles", "SwarmCanvasHost.cs"));
        string page = File.ReadAllText(Path.Combine(
            root, "windows", "app", "OpenBurnBar.App", "Dashboard", "DashboardPage.xaml"));

        Assert.Contains("private readonly DashboardBackdrop _backdrop", kernel, StringComparison.Ordinal);
        Assert.Contains("_backdrop.SetKernel(kernelId)", kernel, StringComparison.Ordinal);
        Assert.DoesNotContain("CoreWebView2", kernel, StringComparison.Ordinal);
        Assert.DoesNotContain("CapturePreviewAsync", kernel, StringComparison.Ordinal);
        Assert.DoesNotContain("new WebView2", kernel, StringComparison.Ordinal);
        Assert.Contains("new CanvasImageSource", swarm, StringComparison.Ordinal);
        Assert.Contains("Control = new Image", swarm, StringComparison.Ordinal);
        Assert.DoesNotContain("new CanvasControl", swarm, StringComparison.Ordinal);
        Assert.DoesNotContain("new CanvasAnimatedControl", swarm, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.AutomationId=\"Dashboard.Content\"", page, StringComparison.Ordinal);
        Assert.Contains("Canvas.ZIndex=\"-30\"", page, StringComparison.Ordinal);
        Assert.Contains("Canvas.ZIndex=\"-20\"", page, StringComparison.Ordinal);
        Assert.Contains("<Grid Canvas.ZIndex=\"10\">", page, StringComparison.Ordinal);
        Assert.Contains("x:Name=\"EggHost\" Canvas.ZIndex=\"20\"", page, StringComparison.Ordinal);
    }

    [Fact]
    public void SemanticWindowCaptureRejectsEmptyCompositionEvidence()
    {
        string root = DistTestSupport.RepositoryRoot();
        string capture = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "tests",
            "ui-automation-harness",
            "OpenBurnBar.UiAutomationHarness",
            "WindowBitmapCapture.cs"));
        string probe = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "tests",
            "ui-automation-harness",
            "OpenBurnBar.UiAutomationHarness",
            "SemanticProbeRunner.cs"));
        string routeRunner = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "tests",
            "ui-automation-harness",
            "OpenBurnBar.UiAutomationHarness",
            "RouteSmokeRunner.cs"));

        Assert.Contains("!printWindowSucceeded || IsNearUniform(bitmap)", capture, StringComparison.Ordinal);
        Assert.Contains("graphics.CopyFromScreen", capture, StringComparison.Ordinal);
        Assert.Contains("SetWindowPos(hwnd, new IntPtr(-1)", capture, StringComparison.Ordinal);
        Assert.Contains("!HasLowerBodyDetail(bitmap)", capture, StringComparison.Ordinal);
        Assert.Contains("capture remained blank or omitted the routed body", capture, StringComparison.Ordinal);
        Assert.Contains("Task.Delay(3_000", probe, StringComparison.Ordinal);
        Assert.DoesNotContain("OPENBURNBAR_DISABLE_WEBVIEW2", routeRunner, StringComparison.Ordinal);
        Assert.DoesNotContain("OPENBURNBAR_DISABLE_WIN2D", routeRunner, StringComparison.Ordinal);
        Assert.Contains("airspace-free CanvasImageSource", routeRunner, StringComparison.Ordinal);
    }

    [Fact]
    public void ShellKeyboardControlsExposeStableAccessibleNames()
    {
        string root = DistTestSupport.RepositoryRoot();
        string shellXaml = File.ReadAllText(Path.Combine(
            root, "windows", "app", "OpenBurnBar.App", "Shell", "AppShell.xaml"));
        string shellCode = File.ReadAllText(Path.Combine(
            root, "windows", "app", "OpenBurnBar.App", "Shell", "AppShell.xaml.cs"));
        string kernelXaml = File.ReadAllText(Path.Combine(
            root, "windows", "app", "OpenBurnBar.App", "Shell", "KernelSwitcherControl.xaml"));

        Assert.Contains("AutomationProperties.Name=\"OpenBurnBar dashboard\"", shellXaml, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.Name=\"Command palette\"", shellXaml, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.Name=\"Appearance\"", shellXaml, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.Name=\"More navigation and settings\"", shellXaml, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.SetName(button, label);", shellCode, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.Name=\"Backdrop kernel\"", kernelXaml, StringComparison.Ordinal);
    }

    [Fact]
    public void StreamingBubbleObservesEveryPretextMeasurementFault()
    {
        string root = DistTestSupport.RepositoryRoot();
        string bubble = File.ReadAllText(Path.Combine(
            root, "windows", "app", "OpenBurnBar.App", "Chat", "StreamingBubble.xaml.cs"));

        Assert.Contains("catch (Exception ex)", bubble, StringComparison.Ordinal);
        Assert.Contains("AppDiagnostics.LogException(\"chat.pretext.measure\", ex);", bubble, StringComparison.Ordinal);
        Assert.Contains("await engine.ReleaseAsync(prepared)", bubble, StringComparison.Ordinal);
    }

    [Fact]
    public void CodePaintedGlassAndBudgetCanvasFollowTheActualTheme()
    {
        string root = DistTestSupport.RepositoryRoot();
        string liquidGlass = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "Theme",
            "LiquidGlass.cs"));
        XNamespace presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
        XDocument budget = XDocument.Load(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "Budget",
            "BudgetPage.xaml"));
        XElement scrollViewer = budget.Descendants(presentation + "ScrollViewer").Single();

        Assert.Contains("border.ActualThemeChanged += OnSurfaceActualThemeChanged;", liquidGlass, StringComparison.Ordinal);
        Assert.Contains("border.ActualTheme);", liquidGlass, StringComparison.Ordinal);
        Assert.Contains("theme == ElementTheme.Light", liquidGlass, StringComparison.Ordinal);
        Assert.Equal("{ThemeResource AuroraCanvasBrush}", (string?)scrollViewer.Attribute("Background"));
    }

    private static ushort ReadUInt16BigEndian(byte[] bytes, int offset) =>
        checked((ushort)((bytes[offset] << 8) | bytes[offset + 1]));

    private static uint ReadUInt32BigEndian(byte[] bytes, int offset) =>
        ((uint)bytes[offset] << 24) |
        ((uint)bytes[offset + 1] << 16) |
        ((uint)bytes[offset + 2] << 8) |
        bytes[offset + 3];
}
