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
            Assert.Equal(
                3,
                shell.Descendants(presentation + "Color").Count(element =>
                    string.Equals((string?)element.Attribute(xaml + "Key"), key, StringComparison.Ordinal)));
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
}
