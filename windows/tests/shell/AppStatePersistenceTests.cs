using System;
using System.Collections.Generic;
using System.IO;
using OpenBurnBar.App.Shell;
using Xunit;

namespace OpenBurnBar.App.Shell.Tests;

/// <summary>
/// Behavioral tests for <see cref="AppStatePersistence"/> — the shell's persisted
/// UI-chrome store (appearance + flyout layout). This type is deliberately pure
/// (<see cref="System.IO"/> + <see cref="System.Text.Json"/>, no WinRT
/// <c>ApplicationData</c>) precisely so the unpackaged shell can use it AND so it is
/// unit-testable off-Windows — these tests exercise that seam on the macOS host.
/// </summary>
public sealed class AppStatePersistenceTests : IDisposable
{
    private readonly string _dir;

    public AppStatePersistenceTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "obb-shell-state-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_dir))
            {
                Directory.Delete(_dir, recursive: true);
            }
        }
        catch (IOException)
        {
            // Best-effort temp cleanup; never fail a test on teardown.
        }
    }

    private string PathFor(string name) => Path.Combine(_dir, name);

    [Fact]
    public void Defaults_WhenNoFileExists()
    {
        var store = new AppStatePersistence(PathFor("missing.json"));

        Assert.Equal("system", store.State.AppearanceMode);
        Assert.Null(store.State.ReduceTransparency);
        Assert.Equal(0d, store.State.FlyoutWidth);
        Assert.Equal(0d, store.State.FlyoutHeight);
        Assert.Empty(store.State.FlyoutModuleOrder);
    }

    [Fact]
    public void RoundTrip_PersistsEveryField()
    {
        var path = PathFor("state.json");

        var first = new AppStatePersistence(path);
        first.State.AppearanceMode = "highcontrast";
        first.State.ReduceTransparency = true;
        first.State.FlyoutWidth = 420.5;
        first.State.FlyoutHeight = 640.25;
        first.State.FlyoutModuleOrder = new List<string> { "quota", "chat", "memory" };
        first.Save();

        var reloaded = new AppStatePersistence(path);

        Assert.Equal("highcontrast", reloaded.State.AppearanceMode);
        Assert.Equal(true, reloaded.State.ReduceTransparency);
        Assert.Equal(420.5, reloaded.State.FlyoutWidth);
        Assert.Equal(640.25, reloaded.State.FlyoutHeight);
        Assert.Equal(new[] { "quota", "chat", "memory" }, reloaded.State.FlyoutModuleOrder);
    }

    [Fact]
    public void RoundTrip_PreservesExplicitFalseReduceTransparency()
    {
        var path = PathFor("reduce-false.json");

        var first = new AppStatePersistence(path);
        first.State.ReduceTransparency = false;
        first.Save();

        var reloaded = new AppStatePersistence(path);

        // false must survive as false (distinct from null = "follow the OS").
        Assert.Equal(false, reloaded.State.ReduceTransparency);
    }

    [Fact]
    public void Save_CreatesMissingParentDirectory()
    {
        var path = Path.Combine(_dir, "nested", "deeper", "state.json");
        Assert.False(File.Exists(path));

        var store = new AppStatePersistence(path);
        store.State.AppearanceMode = "dark";
        store.Save();

        Assert.True(File.Exists(path));
    }

    [Theory]
    [InlineData("{ this is not valid json")]
    [InlineData("")]
    [InlineData("null")]
    public void MalformedOrNullFile_FallsBackToDefaults(string contents)
    {
        var path = PathFor("corrupt.json");
        File.WriteAllText(path, contents);

        var store = new AppStatePersistence(path);

        // A corrupt / empty / literal-null file must degrade to defaults, never throw.
        Assert.Equal("system", store.State.AppearanceMode);
        Assert.Null(store.State.ReduceTransparency);
        Assert.Empty(store.State.FlyoutModuleOrder);
    }

    [Fact]
    public void Save_OmitsReduceTransparency_WhenNull()
    {
        var path = PathFor("omit-null.json");

        var store = new AppStatePersistence(path);
        // ReduceTransparency stays null (follow-the-OS); DefaultIgnoreCondition should drop it.
        store.Save();

        var json = File.ReadAllText(path);
        Assert.DoesNotContain("reduceTransparency", json);
    }

    [Fact]
    public void Save_WritesCamelCaseSchema()
    {
        var path = PathFor("schema.json");

        var store = new AppStatePersistence(path);
        store.State.AppearanceMode = "light";
        store.State.ReduceTransparency = true;
        store.State.FlyoutWidth = 360;
        store.State.FlyoutHeight = 520;
        store.State.FlyoutModuleOrder = new List<string> { "dashboard" };
        store.Save();

        var json = File.ReadAllText(path);

        // Lock the persisted JSON contract (mirrors the [JsonPropertyName] attributes).
        Assert.Contains("\"appearanceMode\"", json);
        Assert.Contains("\"reduceTransparency\"", json);
        Assert.Contains("\"flyoutWidth\"", json);
        Assert.Contains("\"flyoutHeight\"", json);
        Assert.Contains("\"flyoutModuleOrder\"", json);
    }

    [Fact]
    public void DefaultPath_IsUnderLocalAppData_OpenBurnBar()
    {
        var path = AppStatePersistence.DefaultPath();
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        Assert.StartsWith(root, path);
        Assert.Contains("OpenBurnBar", path);
        Assert.EndsWith("shell-state.json", path);
    }
}
