# `windows/app/OpenBurnBar.App/Pet` — PetCompanion WinUI shell

The WinUI render of the desktop PetCompanion (Phase 4 · G4). This folder is the thin
Windows shell over the portable pet brain in
[`OpenBurnBar.App.Pet`](../../OpenBurnBar.App.Pet) and the overlay window in
[`windows/pal/overlay`](../../../pal/overlay).

| File | Role | Verified |
|------|------|----------|
| `WebView2PetGltfHost.cs` | `IPetGltfHost` over an overlay WebView2 (three.js) | Windows dev-host / CI |
| `PetOverlayWindow.xaml(.cs)` | transparent, click-through overlay window hosting the pet + bubble | Windows dev-host / CI |
| `PetChatBubbleView.xaml(.cs)` | the speech bubble, bound to `PetChatBubbleViewModel` (reuses the landed Chat VM) | Windows dev-host / CI |

The behavior graph, chat-event bridge, reaction brain, petdef parser, glTF scene
controller, overlay style math, and per-pixel hit-test are all **portable and
macOS-tested** (`windows/tests/pet`). Only the WinUI/WebView2/Win32 glue in this
folder is Windows-gated, exactly like every other WinUI surface in this port
(XamlCompiler + WebView2 are Windows-only).

## glTF runtime host decision — **WebView2 + three.js** (not native)

The 3D pet is rendered by three.js inside a transparent WebView2, reusing the landed
offscreen-WebView2 bridge pattern that already ships the Pretext text engine
(`windows/pretext` + `.../Pretext/WebView2PretextHost.cs`).

**Why WebView2 + three.js:**

1. **Asset reuse — zero re-authoring.** The 115 committed `.glb` pets under
   `AgentLens/PetCompanion/Resources/Models/` are the *same* assets the shared
   `petcore` web NPC already renders with three.js (`agent.webFunction: "chat"`).
   three.js `GLTFLoader` + `DRACOLoader` load them unmodified — including the
   **Draco-compressed** clips that the macOS renderer decodes via
   `OpenBurnBarDracoDecompressor.mm`.
2. **Bridge reuse.** The WebView2 host, virtual-host mapping, message transport, and
   hardening are already proven by the Pretext lane. `WebView2PetGltfHost` mirrors
   `WebView2PretextHost` method-for-method.
3. **Transparent compositing.** A transparent WebView2 (`alpha:true`,
   `premultipliedAlpha:true`, clear-color α=0) composites cleanly over the
   `WS_EX_LAYERED` overlay, so the pet's silhouette shows over the desktop.
4. **Cross-platform parity.** The behavior graph + reaction contract are shared with
   the web NPC + macOS; a three.js host keeps the *render* on the same shared
   pipeline instead of forking a Windows-only animation runtime.

**Why not native (Win2D / DirectX):** it would require writing a glTF 2.0 parser, a
Draco decoder binding, and a skinned-animation/morph-target runtime from scratch —
a large, high-risk surface with **no reuse** of the existing web pipeline, for a pet
that is already rendered by three.js everywhere else.

**One `.glb` loads through this path:** `claudecode-crab.glb` (the Claude Code
sweeper, `AgentLens/PetCompanion/Resources/Models/claudecode-crab.glb`), driven by
`PetGltfSceneController.LoadModelAsync(...)` → `PlayClipAsync("idle", loop:true)`.

The three.js runtime is dev-host-vendored under
`../../OpenBurnBar.App.Pet/Gltf/Resources/PetGltf/vendor/` (provenance in that
folder's README) rather than committed as a ~1 MB blob.
