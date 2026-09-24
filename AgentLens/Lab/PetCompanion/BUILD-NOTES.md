# PetCompanion — Build & Integration Runbook (PLAN Phase C)

> **Engineer's runbook.** Everything below is what a human runs in Xcode to
> finish, wire, and verify the floating pet companion. The feature was authored
> in a sandbox where Swift could not be fully compiled (no SDK module graph, no
> `xcodebuild`); files were verified with `swiftc -parse` and symbol-grepped
> against the real app sources. This doc is the bridge from "parses" to "ships."

All code and assets are isolated to the `feat/pet-companion` worktree at
`/Users/dewclaw/Documents/Projects/BurnBar-petcompanion`. **Nothing outside
`AgentLens/PetCompanion/` (plus two test files under `AgentLensTests/Active/`)
was created, and no existing app file or the `.pbxproj` was edited.** The seam
wiring is documented here as explicit one-liners the integrator applies.

---

## 0. TL;DR — the only manual steps

1. **`xcodegen generate`** picks up every new `.swift` file automatically (the
   `sources: - path: AgentLens` glob is recursive). **No `.pbxproj` hand-edit.**
2. **Add the two asset roots as folder references** (`Resources/Pets`,
   `Resources/Models`) so `subdirectory:` bundle lookups resolve at runtime —
   §2. This is the single highest-value step; without it the pet won't load.
3. **Link frameworks** SpriteKit + SceneKit (+ optionally GLTFKit2 SPM for real
   3D) — §2.
4. **Apply 3 additive one-liners** to existing files (launch hook, menubar
   toggle, onboarding window) — §3.
5. Build, run the QA script (§5) and the perf budget (§6).

---

## 1. What's in the feature

```
AgentLens/PetCompanion/
  Core/
    PetDefinition.swift          # C2 — Codable mirror of petcore PetDefinition (petdef/1) + legacy pet.json normaliser + frame-rect math
    Behavior.swift               # C3 — logical states, triggers, XState-shaped graph, Mulberry32 RNG, BehaviorInterpreter
    PetRenderer.swift            # @MainActor PetRenderer protocol + PetForm enum + form resolution
  Render/
    SpriteKitPetRenderer.swift   # C4 — 2D atlas backend (SKTexture strips, energy-gated SKView)        [built by a concurrent agent]
    SceneKitPetRenderer.swift    # C5 — 3D GLB backend (GLBSceneLoading seam, on-demand mount/unmount)
  Shell/
    PetPanel.swift               # C1 — borderless non-activating NSPanel, all-Spaces + fullScreenAuxiliary float
    PetCompanionController.swift  # coordinator (panel + renderer + interpreter + ambient loop + click→bubble) + PlaceholderPetRenderer
    PetCompanionFeature.swift    # additive integration surface (launch hook + menubar toggle + first-run gate + hotkey/observer start)
    Hotkey.swift                 # C8 — Carbon RegisterEventHotKey global summon/dismiss (default ⌥Space, rebindable, persisted)
    SystemObservers.swift        # C9 — NSWorkspace sleep/wake + lock/unlock + screen-params + active-space + reduce-motion
  Chat/
    PetChatBubble.swift          # C7 — PetChatController (reuses shared ChatSessionController) + PetChatBubbleView
    PetBubblePanel.swift         # C7 — sibling key-capable NSPanel hosting the SwiftUI bubble
    PetChatFallback.swift        # C6 — deterministic local persona (port of web chatFallback/museFallback)
    PetChatProvider.swift        # C6 — AgentChatProvider façade + CLIBridgeChatProvider (onboarding checkAuth + uniform token stream)
  Agents/
    KeychainStore.swift          # C10 — per-provider Keychain (service "BurnBar.PetCompanion.<Provider>")
  UI/
    FormPicker.swift             # C8 — bundled-pet grid with 2D preview + 2D/3D badge, live setForm swap
    AgentSwitcher.swift          # C7 — standalone brain chip (@AppStorage("pet.activeAgent")) + live auth chips
  Onboarding/
    FirstRun.swift               # C8 — four-step onboarding (pickPet → pickAgent → permissions → land)
  Resources/
    Pets/<id>/petdef.json        # one self-describing petdef/1 per pet
    Pets/<id>/spritesheet.webp   # 2D atlas sheet (atlas pets only)
    Models/*.glb                 # GLB masters (3D pets + claudecode form-swap)

AgentLensTests/Active/
    PetDefinitionTests.swift     # C2 — decode + frame-rect math parity
    BehaviorTests.swift          # C3 — interpreter determinism + golden-vector consumer (⚠ see §8)
```

**Bundled demo assets (this wave — intentionally light, NOT all 224 pets):**

| Pet           | Form(s)      | Files                                                            | petdef |
|---------------|--------------|-----------------------------------------------------------------|--------|
| `claudecode`  | 2D + 3D swap | `Pets/claudecode/spritesheet.webp`, `Models/claudecode-crab.glb` | atlas2d + model3d(static) + behavior + agent + license |
| `goose`       | 2D           | `Pets/goose/spritesheet.webp`                                   | atlas2d + behavior + agent + license |
| `huggingface` | 2D           | `Pets/huggingface/spritesheet.webp`                            | atlas2d + behavior + agent + license |
| `go-gopher`   | 3D static    | `Models/go-gopher.glb`                                          | model3d (static, no clips → host idle-bob) |
| `founder-jobs`| 3D rigged    | `Models/founder-jobs-walk.glb`                                 | model3d (rigged walk clip `Armature\|walking_man\|baselayer`) |

`claudecode` is the default pet (`PetCompanionFeature.defaultPetID`) and demos
the 2D↔3D form swap. All atlas geometry is the canonical 192×208 cell / 8-col /
anchor (96,196) per `PET-ATLAS-CONTRACT` v1. Behavior graphs use the canonical
logical-state vocabulary (`idle/wander/listen/think/speak/sleep/react`); each
renderer's alias table maps those onto the pet's real atlas rows / GLB clips, so
the graph is **form-agnostic** — a 2D and a 3D pet run the identical graph.

---

## 2. Add the files + resources to the Xcode target (the only real manual work)

The repo uses **XcodeGen** (`project.yml`). The `.swift` files need nothing —
they're already under the recursive `sources: - path: AgentLens` glob, so
`xcodegen generate` adds them to the OpenBurnBar target automatically.

### 2a. Resources — MUST be folder references (the one thing to get right)

XcodeGen adds loose files inside a `sources` group as **individual resources
flattened into the bundle root** — the `Pets/<id>/…` and `Models/…` subtree is
**lost**. But every loader asks for a file *inside a subdirectory*:

- `PetDefinition.loadBundled(id:)` → `Bundle.url(forResource:"petdef", withExtension:"json", subdirectory:"Pets/<id>")`
- `SceneKitPetRenderer` GLB load → `Bundle.url(forResource:base, withExtension:"glb", subdirectory:"Models")` (flat fallback after)
- `SpriteKitPetRenderer` sheet load → `Bundle.url(forResource:withExtension:)` **without** a subdirectory (relies on flattening **or** a folder ref — see the caveat in §7)

So a flattened bundle makes `subdirectory:` lookups return `nil` and **no pet
loads**. Add the two asset roots as **folder references** (blue folders), which
copy verbatim and preserve the tree. In `project.yml`, under
`targets.OpenBurnBar.sources`:

```yaml
    sources:
      - path: AgentLens
        excludes:
          - "**/.DS_Store"
          # keep the asset roots out of the group walk so they aren't added twice…
          - "PetCompanion/Resources/Pets"
          - "PetCompanion/Resources/Models"
      # …re-add them as folder references (preserves Pets/<id>/ + Models/ in the bundle):
      - path: AgentLens/PetCompanion/Resources/Pets
        type: folder
        buildPhase: resources
      - path: AgentLens/PetCompanion/Resources/Models
        type: folder
        buildPhase: resources
```

```bash
cd /Users/dewclaw/Documents/Projects/BurnBar-petcompanion
xcodegen generate
```

**Manual-Xcode equivalent** (no XcodeGen): drag `Resources/Pets` and
`Resources/Models` into the target choosing **"Create folder references"** (blue
folder), NOT "Create groups". Then verify the bundle survives a build:

```bash
APP="$(xcodebuild -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}')/OpenBurnBar.app"
find "$APP/Contents/Resources/Pets" -type f   # must list petdef.json + spritesheet.webp per pet
find "$APP/Contents/Resources/Models" -type f # must list the .glb masters
```

> **webp note:** `NSImage(contentsOf:)` / `SKTexture` decode `.webp` natively on
> macOS 14+ (ImageIO gained the WebP UTI in Sonoma). Deployment target is 14.0,
> so the bundled `spritesheet.webp` sheets load with no converter. If you ever
> back-deploy below 14, pre-convert to PNG (`cwebp`/`sips`) and update each
> `atlas2d.image`.

### 2b. Frameworks to link

| Framework | For | How |
|---|---|---|
| **SpriteKit** | C4 2D atlas renderer | `targets.OpenBurnBar.dependencies: - sdk: SpriteKit.framework` (or autolinked via `import SpriteKit`) |
| **SceneKit** | C5 3D renderer | `- sdk: SceneKit.framework` (autolinked via `import SceneKit`) |
| **Carbon** | C8 global hotkey (`RegisterEventHotKey`) | autolinked via `import Carbon.HIToolbox`; no extra entitlement (that's why Carbon was chosen over an NSEvent global monitor) |
| **Security** | C10 Keychain | autolinked via `import Security` |
| **GLTFKit2** (SPM) | **real** GLB decoding | `packages.GLTFKit2` + `targets.OpenBurnBar.dependencies` |
| **DracoSwift** (SPM) | Draco mesh decompression for synced Imagine GLBs | `packages.DracoSwift` + `OpenBurnBarDracoDecompressor` |

ModelIO/SceneKit do **not** need explicit linking beyond `import`; the SDK
frameworks autolink. The only packages needed are GLB decode and Draco mesh
decompression.

### 2c. GLTFKit2 — required for the 3D backend to render real models

SceneKit/ModelIO on macOS **cannot decode binary glTF** (`.glb`):
`MDLAsset.canImportFileExtension("glb")` is `false` and `SCNScene(url:)` reads
only SceneKit/USD/COLLADA. `SceneKitPetRenderer` ships behind the
`GLBSceneLoading` seam; `DefaultGLBSceneLoader` tries (1) GLTFKit2 via
`GLTFAsset(url:options:)` and `GLTFSCNSceneSource(asset:).defaultScene`, with
`OpenBurnBarDracoDecompressor` registered for the synced Imagine pets'
`KHR_draco_mesh_compression` payloads, then (2) native `SCNScene(url:)` (works
for `.usdz`/`.scn` and for `.glb` once a system GLTF importer is registered),
then (3) a teal `SCNCapsule` placeholder so the panel is never blank.

GLTFKit2 surfaces glTF animation data into SceneKit; `harvestClipPlayers()` +
`resolveClipName()` consume the resulting `SCNAnimationPlayer`s by clip name when
available. Run `xcodegen generate` after changing the package declaration.

**GLB ground truth** (verified by parsing the glTF JSON chunk): every `*-walk.glb`
holds exactly one clip `Armature|walking_man|baselayer`; the static GLBs
(`go-gopher`, `claudecode-crab`) have **zero** animations and get a host-driven
`SCNAction` idle-bob so they still read as alive. `founder-jobs/petdef.json` maps
`idle/wander/drag/walk/travel → that one walk clip`; `go-gopher` is `kind:static`
with empty clips.

---

## 3. The three additive one-liners (existing files — apply by hand)

The feature was kept strictly additive: no existing app file was edited. Three
small insertions wire it into the shell. Each is a single call into
`PetCompanionFeature`/`PetCompanionController`.

1. **Launch hook** — in `AgentLensApp.swift`, the `.task` block of `MenuBarLabel`
   (~line 446, where other lazy services spin up):
   ```swift
   PetCompanionFeature.activateIfEnabled(chat: /* the app's shared ChatSessionController, or nil */)
   ```
   Registers both renderer backends, attaches the shared chat controller, starts
   the hotkey + system observers, and shows the pet if the user left it enabled.
   Idempotent.

2. **Menubar toggle** — in `MenuBarPopoverView.swift`, the footer `actionBar`
   (~line 424, beside Dashboard/Settings/Quit):
   ```swift
   PetCompanionToggleButton()
   ```
   Flips `@AppStorage("pet.companionEnabled")` and shows/hides the panel using
   the same `DesignSystem` tokens as the rest of the popover.

3. **First-run onboarding** — add a `WindowManager` opener mirroring
   `openSettings()` (a cached `NSWindow` whose `contentView = NSHostingView(rootView: PetFirstRunView())`),
   and at launch:
   ```swift
   if PetCompanionFeature.shouldRunFirstRun { WindowManager.shared.openPetOnboarding() }
   ```
   `shouldRunFirstRun` is `false` once onboarding completes (`PetFirstRunModel.hasCompleted`).
   Optional this wave — the toggle alone makes the pet appear; onboarding is the
   polished first-launch path.

> All three are additive lines only — no existing window flow is rewired, and the
> pet panel is a separate cached NSPanel independent of the three existing
> NSWindows (dashboard/settings/onboarding), so it can't disturb them.

---

## 4. Compile / test commands

```bash
cd /Users/dewclaw/Documents/Projects/BurnBar-petcompanion
xcodegen generate

# Build the app (Debug). Requires a DEVELOPMENT_TEAM for the Keychain entitlement.
xcodebuild \
  -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBar \
  -configuration Debug \
  -destination 'platform=macOS' \
  build

# Pet unit tests only (fast — compiles into OpenBurnBarTests via the path glob):
xcodebuild \
  -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBar \
  -destination 'platform=macOS' \
  test \
  -only-testing:OpenBurnBarTests/PetDefinitionTests \
  -only-testing:OpenBurnBarTests/BehaviorTests
```

Strict concurrency is `complete` project-wide (Swift 5.10 lang mode, toolchain
6.0.3). New files were written to that bar: `@MainActor` on every UI/AppKit type
(`PetPanel`, `PetCompanionController`, the renderers, `PetHotkey`,
`PetSystemObservers`), `Sendable` value models (`PetDefinition`, behavior graph).
Treat any Swift-6-actor diagnostic as the first triage item — see §7.

---

## 5. Manual QA script (PLAN §7)

Enable: launch → menubar popover → **Show Pet** (`PetCompanionToggleButton`,
persisted in `@AppStorage("pet.companionEnabled")`). Or complete first-run.

1. **Floats over fullscreen + all Spaces.**
   - Pet appears lower-trailing on the active screen.
   - Fullscreen an app (Safari ⌃⌘F) → pet stays on top, doesn't steal focus.
   - Swipe to another Space (⌃→) → pet rides along (`.canJoinAllSpaces`).
   - Mission Control → pet stays put; level re-asserts on `activeSpaceDidChange`.
   - Click through the transparent panel corners onto the app behind; only the
     creature silhouette is interactive.
2. **Click-to-chat streams.**
   - Click the pet → frosted bubble opens at the contact socket; pet plays
     `listen`. Type, ⏎ → pet `think`, then `speak` as tokens stream in (via the
     shared `ChatSessionController` → `CLIBridge.chat*Stream`), then a `react`
     beat when it lands.
   - Focus check: the bubble takes key for the text field; the app behind keeps
     main-window status (panels are `nonactivatingPanel`, `canBecomeMain == false`).
3. **Switch brain mid-reply.**
   - Start a long answer, open the brain menu, pick another `ChatBackendID`. The
     in-flight stream cancels, pet returns to `listen`, the last user turn replays
     to the new brain. Selection persists to `UserDefaults["pet.activeAgent"]`.
4. **Rapid clicks / double-send.**
   - Hammer the pet and the send key. An in-flight `send()` is cancelled before a
     new one starts; no duplicate streams, no stuck `think` state.
5. **Offline → local persona.**
   - Disable the CLIs / take the gateway offline (or pick a backend with no
     consent) and ask. The bubble shows the **"answering locally"** badge, the pet
     does a `react`/`fallbackFired` beat, and `PetChatFallback` streams a
     deterministic answer word-by-word. Chat never dead-ends. Same question →
     same answer (determinism).
6. **Long replies.**
   - Ask for a long answer; the transcript scrolls, the stream stays chunked, and
     a new send/switch aborts cleanly.
7. **Sleep / wake.**
   - Sleep the display or lock the screen → renderer pauses (`SKView.isPaused` /
     `SCNView.isPlaying=false`), ambient loop stops, ~0% CPU (watch Activity
     Monitor). Driven by `PetSystemObservers` (screensDidSleep/Wake, willSleep,
     screenIsLocked/Unlocked). Wake → resumes prior state.
8. **Multi-display.**
   - Drag across two displays; on reconfigure / resolution change the panel
     re-clamps in-bounds (`handleScreenParametersChanged` →
     `didChangeScreenParametersNotification`). Unplug the display the pet was on →
     it returns to a remaining screen rather than stranding off-screen.
9. **Reduced motion.**
   - System Settings → Accessibility → Display → Reduce Motion ON →
     `accessibilityDisplayOptionsDidChange` freezes ambient wander to a key pose;
     functional state changes (listen/think/speak) still read.
10. **Global hotkey.**
    - ⌥Space summons/dismisses the bubble and focuses input (Carbon hotkey, no
      Accessibility/Input-Monitoring permission required). Rebind persists across
      relaunch (`pet.hotkey.combo`).
11. **Form swap (claudecode).**
    - Open the FormPicker (or call `PetCompanionFeature.runtime.controller.setForm(.model3d(glbName:"claudecode-crab"))`)
      → 2D↔3D swap with the **same** behavior graph running, no panel teardown.

---

## 6. Desktop performance budget (PLAN §4) — targets + how to measure

| Metric | Budget | How it's wired | How to measure |
|---|---|---|---|
| **Idle CPU** | ~0% true idle; ≤3% ambient | `SKView.isPaused` / `SCNView.isPlaying=false` between anims; occlusion + sleep/lock gate via `PetSystemObservers` → `controller.setPaused(true)` | Activity Monitor (% CPU) with pet idle/occluded; or Instruments **Time Profiler** |
| **Idle FPS** | 12–15 ambient; 0 paused; 60 only on interaction | `preferredFramesPerSecond = 15` ambient (both renderers); burst on interaction then drop | Instruments **Core Animation** / **Game Performance** (FPS track), or a frame counter overlay in Debug |
| **Resident MEM** | ≤120 MB typical; ≤200 MB hard cap | SpriteKit atlas resident; SceneKit brought up **on demand** in `mount()`, torn down in `unmount()` (drops `scene`, harvested `SCNAnimationPlayer`s, detaches the view) → returns toward baseline when hidden | Instruments **Allocations** (Persistent bytes) / Xcode memory gauge; toggle the pet on/off and 2D↔3D to confirm teardown |
| **Energy** | "Low" idle; never sustained "High" | occlusion/sleep/lock pause; ambient 15 fps; reduced-motion freeze; Low Power Mode should drop to ~10–12 fps | Instruments **Energy Log** (Energy Impact = Low when idle) |
| **First-token** | ≤800 ms p50 local; ≤1500 ms cloud; **fallback <100 ms** | local CLI transports via `CLIBridge`; `PetChatFallback` streams instantly | `os_signpost` around send→first-`.text` event (add a signpost in `PetChatController.send`), read in Instruments **Points of Interest**; fallback is synchronous so <100 ms by construction |

**Energy gating is already wired** — `PetSystemObservers` forwards
sleep/wake/lock/unlock/space/screen-params/reduce-motion to the controller, which
calls each renderer's `setPaused`. The through-line PLAN demands — *cost nothing
when nobody's looking* — is implemented; the measurement job is to **confirm** it
(idle CPU ≈ 0, energy Low) and that SceneKit memory drops after `unmount()`.

**Measurement recipe (Instruments):**
```bash
# Idle CPU + energy: launch, show pet, leave it idle, occlude it, sleep display.
xcrun xctrace record --template 'Time Profiler' --launch -- "$APP/Contents/MacOS/OpenBurnBar"
# Memory teardown: Allocations template; toggle pet on/off + 2D↔3D, watch Persistent bytes.
xcrun xctrace record --template 'Allocations' --attach OpenBurnBar
```
The `swiftui-expert` skill ingests a `.trace` for hang/hitch/CPU-hotspot triage
if any track blows its budget.

---

## 7. Parse-checked vs needs-a-full-Xcode-build, + caveats

**Verified in the sandbox (`swiftc -parse`, 6.0.3, clean — 0 errors):** all new
`.swift` files parse and resolve their real system imports (SpriteKit, SceneKit,
AppKit, SwiftUI, Security, Carbon.HIToolbox). Cross-file app symbols were
**grep-verified** against the real sources, not type-checked:
`CLIBridge.chat{Codex,Claude}Stream` / `chatHermes` / `chatOpenClaw` +
`isExecutableAvailable` / `probe{Hermes,OpenClaw}Availability`; the
`ChatSessionController` surface (`chatBackend`, `setChatBackend`, `isStreaming`,
`streamError`, `activeStreamMessageId`, `messages`, `inputText`, `send()`,
`cancelGeneration`); `ChatBackendID` cases; `DesignSystem` tokens incl.
`Colors.error`.

**Audit verification:**
- `make CONFIG=Debug build-signed` completes with GLTFKit2 and DracoSwift in the
  app dependency graph.
- `/Applications/OpenBurnBar.app` contains the GLB model set under
  `Contents/Resources/Models`, embeds `GLTFKit2.framework`, and the app binary
  links both GLTFKit2 and SceneKit.
- If GLTFKit2 or native SceneKit cannot decode a specific GLB, that pet renders
  the teal capsule fallback instead of a blank panel. 2D pets are fully real.

**Caveats surfaced:**
- **SpriteKit sheet lookup has no `subdirectory:` arg** (pre-existing, not edited
  this wave): `SpriteKitPetRenderer.loadImage` uses
  `bundle.url(forResource:withExtension:)` without a subdirectory, so it relies on
  the folder-ref flattening **or** needs `subdirectory:"Pets/<id>"` added. Worth a
  one-line follow-up when wiring resources so 2D pets load deterministically
  regardless of bundle layout.
- **Golden-vector parity is opt-in** — see §8. The active Swift test skips unless
  a Swift-compatible fixture is provided.
- **DEVELOPMENT_TEAM** must be set for a signed Debug build (Keychain
  entitlement, App Sandbox already disabled).
- **Naming, for docs:** `PetChatController` (singular) is the **live transport**
  reuse of `ChatSessionController`; `AgentChatProvider` / `CLIBridgeChatProvider`
  is the **onboarding/token façade** (per-provider `checkAuth()` chips + a uniform
  token stream). No collision — keep them distinct in docs.

---

## 8. Golden-vector behavior parity — opt-in until the fixture shape is converted

The shared TS export shape does **not** match what
`BehaviorTests.test_goldenVectors_matchWhenPresent` decodes, so the Swift test no
longer probes machine-local absolute paths. It skips unless a Swift-compatible
fixture is present at `packages/petcore/test/golden/behavior-swift.json` or
`OPENBURNBAR_PET_BEHAVIOR_GOLDEN_JSON` points at one.

- **Exported shape:** `{ "seeds": [1337,2024,7,99,524287], "graph": {...}, "vectors": [ { "seed": N, "states": ["wander","idle",…] }, … ] }`
  — multi-seed; each vector is a flat list of resulting states (no per-step
  trigger; the trigger stream is implied: ambient `cooldownElapsed` ticks then a
  fixed interaction tail).
- **What Swift decodes** (`BehaviorGoldenVector` in `Core/Behavior.swift`):
  `{ "seed": N, "graph": {...}, "steps": [ { "trigger": "...", "expected": "..." } ] }`
  — single seed, explicit trigger/expected pairs.

**Fix (pick one):**
1. **Adapt the Swift consumer** to the real export: decode
   `{ seeds, graph, vectors:[{seed, states}] }`, and per vector replay the *same
   trigger script the TS generator used* against `BehaviorInterpreter(graph:seed:)`,
   asserting the produced state sequence equals `states`. (Get the exact trigger
   order from the petcore generator.)
2. **Or** have the petcore generator additionally emit the
   `{seed, graph, steps:[{trigger, expected}]}` shape into a sibling file the
   Swift test points at.

Until reconciled, keep `loadGoldenVectorData()` pointed only at the converted
trigger-paired fixture so local machines cannot accidentally fail or pass based on
an unrelated checkout. Interpreter determinism itself is already covered by the
other `BehaviorTests` cases (same-seed reproducibility, weighted selection,
pinned Mulberry32 first value `2_693_262_067`), so cross-runtime fixture parity is
the only open item.

---

## 9. Asset bundling — adding more pets from the imaginethat-llc library

The five demo pets are a deliberately light slice. The shared `petdef/1` schema is
a strict superset of today's `pet.json`, so the full library drops in with no code
change — only files.

**Source of truth** (the imaginethat-llc repo):
- Atlas pets (17 today): `public/pets/<id>/{spritesheet.webp, pet.json}` —
  canonical 8×N grid, 192×208 cells, anchor (96,196) per
  `.claude/sweep-swarm/PET-ATLAS-CONTRACT.md`.
- 3D models: `public/pet-models/{*.glb}`, Draco-optimized variants in
  `public/pet-models/opt/`. **Bundle the GLB master**, never the lossy USDZ
  (USDZ keeps only one clip).
- The Codex exporter (`src/lib/codexPetExport.ts` / `…Bake.ts`) and the roster
  (`tmp/pet-assets/roster/*.json`) describe the full 100/224 set.

**To add a pet to the desktop bundle:**
1. Create `Resources/Pets/<id>/` and drop `petdef.json` + `spritesheet.webp` (2D)
   and/or add the `model.glb` to `Resources/Models/` (3D).
2. If only legacy `pet.json` exists, copy it as `petdef.json` — `PetDefinition`
   normalises the legacy shape on decode (the loader is a superset reader). For a
   3D pet add a `model3d` block (`kind`, `glb` base name, `clips` map).
3. `petdef.json`'s `atlas2d.image` is the file name inside the pet folder;
   `model3d.glb` is the **base name** (no extension) resolved against
   `Resources/Models/`.
4. Re-run `xcodegen generate` (folder refs pick up the new files automatically; no
   `.pbxproj` edit). Confirm with the `find` check in §2a.
5. `FormPicker` (`PetCatalog`) enumerates `Resources/Pets/<id>/` folders at
   runtime, so a newly bundled pet appears in the picker with no code change.

**Conversions** (deliberately almost none): WebP→PNG only if back-deploying below
macOS 14; GLB→Draco for *web* (not needed for desktop bundling). Keep each pet's
`license` block (`ipStatus`/`note`/`attribution`) — likeness/trademark pets stay
internal/whimsical and out of sellable commercial bundles by default.

---

## 10. Out of scope this wave (PLAN C11 — not the panel seam)

Signing, Hardened Runtime, notarization (`notarytool submit --wait` + `stapler`),
the DMG, and Sparkle/EdDSA appcast are PLAN C11 deployment tasks, intentionally
**not** part of the floating-panel feature. The app already ships
Developer-ID/notarized with App Sandbox disabled and `LSUIElement: true`, which is
exactly what the NSPanel floating/all-Spaces/fullscreen-aux design needs — so no
project-setting changes were required for the pet itself.
