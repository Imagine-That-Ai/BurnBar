using System.Threading.Tasks;
using OpenBurnBar.App.Pet.Gltf;
using Xunit;

namespace OpenBurnBar.App.Pet.Tests;

public sealed class PetGltfSceneControllerTests
{
    [Fact]
    public async Task Start_AwaitsReadyHeartbeat()
    {
        var host = new FakePetGltfHost();
        using var scene = new PetGltfSceneController(host);
        Assert.False(scene.IsReady);
        await scene.StartAsync();
        Assert.True(scene.IsReady);
    }

    [Fact]
    public async Task LoadThenClip_AcksAndTracksState()
    {
        var host = new FakePetGltfHost();
        using var scene = new PetGltfSceneController(host);
        await scene.StartAsync();

        await scene.LoadModelAsync("https://petgltf.invalid/claudecode-crab.glb", draco: true);
        Assert.Equal("https://petgltf.invalid/claudecode-crab.glb", scene.LoadedUrl);

        await scene.PlayClipAsync("idle", loop: true);
        Assert.Equal("idle", scene.CurrentClip);

        // The controller sent a load (draco) then a looping clip.
        Assert.Equal(2, host.Commands.Count);
        Assert.Equal(PetGltfCommand.CmdLoad, host.Commands[0].Cmd);
        Assert.Equal(PetGltfCommand.CmdClip, host.Commands[1].Cmd);
        Assert.True(host.Commands[1].Loop);
    }

    [Fact]
    public async Task RejectedCommand_Throws()
    {
        var host = new FakePetGltfHost();
        using var scene = new PetGltfSceneController(host);
        await scene.StartAsync();

        host.FailNextError = "clip 'nope' not found";
        await Assert.ThrowsAsync<PetGltfCommandException>(() => scene.PlayClipAsync("nope", loop: false));
    }

    [Fact]
    public async Task OneShotClip_RaisesClipEnded()
    {
        var host = new FakePetGltfHost();
        host.EmitClipEndedFor.Add("react");
        using var scene = new PetGltfSceneController(host);

        string? ended = null;
        scene.ClipEnded += name => ended = name;

        await scene.StartAsync();
        await scene.LoadModelAsync("https://petgltf.invalid/x.glb");
        await scene.PlayClipAsync("react", loop: false);

        Assert.Equal("react", ended);
    }

    [Fact]
    public async Task Dispose_TearsDownScene()
    {
        var host = new FakePetGltfHost();
        using var scene = new PetGltfSceneController(host);
        await scene.StartAsync();
        await scene.LoadModelAsync("https://petgltf.invalid/x.glb");
        await scene.DisposeSceneAsync();
        Assert.Null(scene.LoadedUrl);
    }

    [Fact]
    public void EmbeddedShell_CarriesBridgeHooksAndImportMap()
    {
        // Real macOS proof that the three.js shell is embedded + well-formed enough to
        // speak the bridge protocol (the live render is Windows/dev-host-deferred).
        var html = PetGltfShellResources.ReadIndexHtml();
        Assert.Contains("importmap", html);
        Assert.Contains("GLTFLoader", html);
        Assert.Contains("DRACOLoader", html);
        Assert.Contains("window.__petDispatch", html);
        Assert.Contains("\"ready\"", html);
        Assert.Contains("clipEnded", html);
    }

    [Fact]
    public void ExtractTo_WritesIndexHtml()
    {
        var dir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "obb-petgltf-" + System.Guid.NewGuid().ToString("N"));
        try
        {
            var path = PetGltfShellResources.ExtractTo(dir);
            Assert.True(System.IO.File.Exists(path));
            Assert.Contains("three", System.IO.File.ReadAllText(path));
        }
        finally
        {
            if (System.IO.Directory.Exists(dir))
            {
                System.IO.Directory.Delete(dir, recursive: true);
            }
        }
    }
}
