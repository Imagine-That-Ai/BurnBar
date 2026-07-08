using System;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Pet.Gltf;

// MARK: - glTF web-host transport seam
//
// The PetCompanion 3D runtime host decision (see Gltf/README notes on
// PetGltfSceneController) is WebView2 + three.js: it reuses the SAME landed
// offscreen-WebView2 bridge pattern that ships the Pretext text engine
// (windows/pretext IPretextWebHost / windows/app .../Pretext/WebView2PretextHost),
// and it loads the SAME committed `.glb` assets the macOS SceneKit renderer + the
// web NPC already use (three.js GLTFLoader + DRACOLoader handle the Draco-
// compressed clips that OpenBurnBarDracoDecompressor.mm decodes on macOS).
//
// <see cref="PetGltfSceneController"/> is transport-agnostic: it only knows how to
// (a) ask the host to load the three.js shell, (b) push a JSON command into the
// page, and (c) receive JSON replies the page posts back. This interface is the
// seam. The concrete WebView2 host lives in the WinUI app
// (`WebView2PetGltfHost`); the tests supply an in-memory fake so the whole
// protocol is exercised on the macOS authoring host without a browser — exactly
// the split the Pretext engine proved.

/// Transport seam between the portable <see cref="PetGltfSceneController"/> and a
/// concrete web view (real: offscreen/overlay WebView2 on Windows; test: in-memory
/// fake).
public interface IPetGltfHost
{
    /// Load the bundled three.js pet shell (index.html + three bundle). Must be
    /// idempotent. The host raises <see cref="MessageReceived"/> with the readiness
    /// heartbeat (<c>{ "id": 0, "event": "ready" }</c>) once the shell has loaded
    /// and the scene is available.
    Task StartAsync(CancellationToken cancellationToken = default);

    /// Post a JSON command string to the page (the controller hands this the
    /// serialised <see cref="PetGltfCommand"/>). Replies come back over
    /// <see cref="MessageReceived"/>; a transport failure surfaces as a faulted task.
    Task PostMessageAsync(string json, CancellationToken cancellationToken = default);

    /// Raised whenever the page posts a reply/event. The payload is the reply JSON
    /// string (the shape produced by the shell's <c>postReply</c>).
    event Action<string> MessageReceived;
}
