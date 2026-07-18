using System;
using System.IO;
using System.Linq;
using System.Xml.Linq;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class WindowsVisualSourceContractTests
{
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
}
