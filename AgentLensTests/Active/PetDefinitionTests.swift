import AppKit
import SceneKit
import SwiftUI
import XCTest
@testable import OpenBurnBar

/// C2 — decodes a real `petdef.json` (the shipped `claudecode` legacy `pet.json`
/// plus the modern `petdef/1` superset) and proves the Swift frame-rect helper
/// matches the shared TS math (192×208 cells, anchor 96/196).
final class PetDefinitionTests: XCTestCase {
    private let minimumSyncedModelPetCount = 80
    private let bundledFounderIDs = [
        "founder-altman",
        "founder-bezos",
        "founder-gates",
        "founder-huang",
        "founder-jobs",
        "founder-musk",
        "founder-nadella",
        "founder-pichai",
        "founder-zuckerberg"
    ]

    @MainActor
    private final class StubRenderer: PetRenderer {
        let definition: PetDefinition
        let form: PetForm
        let view: NSView

        init(definition: PetDefinition, form: PetForm = .atlas2d(imageName: "sprite.png")) {
            self.definition = definition
            self.form = form
            self.view = NSView(frame: CGRect(x: 0, y: 0, width: 192, height: 208))
        }

        func mount(in container: NSView) {}
        func unmount() {}
        func play(state: String) {}
        func setForm(_ form: PetForm) {}
        func setFacing(_ direction: CGFloat) {}
        func setPaused(_ paused: Bool) {}
        func setAmbientFrameRate(_ fps: Int) {}
    }

    private func bundledModelPetIDs(in bundle: Bundle = .main) -> [String] {
        guard let modelsRoot = bundle.url(forResource: "Models", withExtension: nil),
              let entries = try? FileManager.default.contentsOfDirectory(
                    at: modelsRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
              ) else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("petdef.json").path) }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// All bundled pets that ship a 3D form, including legacy `Pets/` demos
    /// (e.g. go-gopher) and synced `Models/` cast members.
    private func bundledModel3DPetIDs(in bundle: Bundle = .main) -> [String] {
        let roots = ["Models", "Pets"].compactMap { bundle.url(forResource: $0, withExtension: nil) }
        var ids: [String] = []
        for modelsRoot in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: modelsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            ids.append(contentsOf: entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("petdef.json").path) }
                .map { $0.lastPathComponent }
            )
        }
        return Array(Set(ids)).filter { id in
            guard let def = PetDefinition.loadBundled(id: id, in: bundle) else { return false }
            return def.model3d != nil
        }.sorted()
    }

    // MARK: Fixtures

    /// The exact shipped `public/pets/claudecode/pet.json` (legacy PET-ATLAS-
    /// CONTRACT shape: top-level grid/cell/anchor/states).
    private let legacyClaudeCodeJSON = """
    {
      "id": "claudecode",
      "name": "Claude Code",
      "kind": "sweeper",
      "displayName": "Claude Code",
      "description": "Scuttles along the baseline.",
      "spritesheet": "spritesheet.webp",
      "spritesheetPath": "spritesheet.webp",
      "grid": { "cols": 8, "rows": 9 },
      "cell": { "w": 192, "h": 208 },
      "atlas": { "w": 1536, "h": 1872 },
      "anchor": { "x": 96, "y": 196 },
      "states": {
        "idle":        { "row": 0, "frames": 8, "fps":  8, "loop": true  },
        "scuttle":     { "row": 1, "frames": 8, "fps": 10, "loop": true  },
        "pinch_sweep": { "row": 2, "frames": 8, "fps": 10, "loop": true  },
        "claw_scoop":  { "row": 3, "frames": 8, "fps":  9, "loop": false },
        "burrow":      { "row": 4, "frames": 8, "fps":  8, "loop": false },
        "snip":        { "row": 5, "frames": 8, "fps": 11, "loop": true  },
        "cheer":       { "row": 6, "frames": 8, "fps": 11, "loop": false },
        "sleep":       { "row": 7, "frames": 8, "fps":  6, "loop": true  },
        "alert":       { "row": 8, "frames": 8, "fps": 10, "loop": false }
      },
      "default": "idle"
    }
    """

    /// A modern `petdef/1` definition (nested `atlas2d`, behavior, agent).
    private let modernPetdefJSON = """
    {
      "schema": "petdef/1",
      "id": "claudecode",
      "name": "Claude Code",
      "kind": "sweeper",
      "palette": ["#d97757"],
      "atlas2d": {
        "image": "sprite.png",
        "imageWeb": "sprite.webp",
        "grid": { "cols": 8, "rows": 9 },
        "cell": { "w": 192, "h": 208 },
        "anchor": { "x": 96, "y": 196 },
        "states": {
          "idle":  { "row": 0, "frames": 8, "fps": 8,  "loop": true },
          "work":  { "row": 2, "frames": 8, "fps": 10, "loop": true, "hero": true },
          "cheer": { "row": 6, "frames": 8, "fps": 12, "loop": false }
        },
        "default": "idle",
        "sockets": { "contact": { "fx": 0.82, "fy": 0.74 } }
      },
      "behavior": {
        "initial": "idle",
        "transitions": [
          { "from": "idle", "to": "wander", "when": "cooldownElapsed", "weight": 12 }
        ]
      },
      "behaviorMechanic": "SWEEP",
      "locomotion": "scuttle",
      "agent": { "providersDesktop": ["hermes","codex","claude"], "persona": "muse" }
    }
    """

    // MARK: Legacy decode

    func test_decodesLegacyPetJSON_intoAtlas2D() throws {
        let def = try PetDefinition.decode(from: Data(legacyClaudeCodeJSON.utf8))
        XCTAssertEqual(def.id, "claudecode")
        XCTAssertEqual(def.name, "Claude Code")
        XCTAssertEqual(def.kind, "sweeper")

        let atlas = try XCTUnwrap(def.atlas2d, "legacy top-level atlas should normalise into atlas2d")
        XCTAssertEqual(atlas.grid.cols, 8)
        XCTAssertEqual(atlas.grid.rows, 9)
        XCTAssertEqual(atlas.cell.w, 192)
        XCTAssertEqual(atlas.cell.h, 208)
        XCTAssertEqual(atlas.anchor.x, 96)
        XCTAssertEqual(atlas.anchor.y, 196)
        XCTAssertEqual(atlas.defaultState, "idle")
        XCTAssertEqual(atlas.states.count, 9)
        XCTAssertEqual(atlas.states["sleep"]?.row, 7)
        XCTAssertEqual(atlas.states["sleep"]?.fps, 6)
        XCTAssertEqual(atlas.states["alert"]?.loop, false)
        XCTAssertEqual(atlas.image, "spritesheet.webp")
    }

    // MARK: Modern decode

    func test_decodesModernPetdef() throws {
        let def = try PetDefinition.decode(from: Data(modernPetdefJSON.utf8))
        XCTAssertEqual(def.schema, "petdef/1")
        let atlas = try XCTUnwrap(def.atlas2d)
        XCTAssertEqual(atlas.image, "sprite.png")
        XCTAssertEqual(atlas.imageWeb, "sprite.webp")
        XCTAssertEqual(atlas.states["work"]?.hero, true)
        XCTAssertEqual(atlas.socketPoint("contact"),
                       CGPoint(x: 0.82 * 192, y: 0.74 * 208))

        XCTAssertEqual(def.behavior?.initial, "idle")
        XCTAssertEqual(def.behavior?.transitions.first?.when, .cooldownElapsed)
        XCTAssertEqual(def.behavior?.transitions.first?.effectiveWeight, 12)
        XCTAssertEqual(def.agent?.providersDesktop, ["hermes", "codex", "claude"])
        XCTAssertEqual(def.behaviorMechanic, "SWEEP")
    }

    @MainActor
    func test_defaultRendererSocketPoint_flipsAtlasYForAppKitCoordinates() throws {
        let def = try PetDefinition.decode(from: Data(modernPetdefJSON.utf8))
        let renderer = StubRenderer(definition: def)

        let point = try XCTUnwrap(renderer.socketPoint("contact"))

        XCTAssertEqual(point.x, 0.82 * 192, accuracy: 0.0001)
        XCTAssertEqual(point.y, (1.0 - 0.74) * 208, accuracy: 0.0001)
    }

    // MARK: Frame-rect math (matches TS A2)

    func test_frameRect_matchesTSMath() throws {
        let def = try PetDefinition.decode(from: Data(modernPetdefJSON.utf8))
        let atlas = try XCTUnwrap(def.atlas2d)

        // work row = 2 → y = 2 * 208 = 416; frame 0 → x = 0.
        let work0 = try XCTUnwrap(atlas.frameRect(state: "work", frame: 0))
        XCTAssertEqual(work0, CGRect(x: 0, y: 416, width: 192, height: 208))

        // frame 3 → x = 3 * 192 = 576.
        let work3 = try XCTUnwrap(atlas.frameRect(state: "work", frame: 3))
        XCTAssertEqual(work3, CGRect(x: 576, y: 416, width: 192, height: 208))

        // idle row = 0 → y = 0.
        let idle5 = try XCTUnwrap(atlas.frameRect(state: "idle", frame: 5))
        XCTAssertEqual(idle5, CGRect(x: 5 * 192, y: 0, width: 192, height: 208))
    }

    func test_frameRect_clampsOverrun() throws {
        let def = try PetDefinition.decode(from: Data(modernPetdefJSON.utf8))
        let atlas = try XCTUnwrap(def.atlas2d)
        // 8 frames (0...7); frame 99 clamps to 7 → x = 7 * 192.
        let clamped = try XCTUnwrap(atlas.frameRect(state: "idle", frame: 99))
        XCTAssertEqual(clamped.minX, 7 * 192)
    }

    func test_frameRect_unknownStateReturnsNil() throws {
        let def = try PetDefinition.decode(from: Data(modernPetdefJSON.utf8))
        let atlas = try XCTUnwrap(def.atlas2d)
        XCTAssertNil(atlas.frameRect(state: "nope", frame: 0))
    }

    func test_atlasPixelSize_derivesFromGridAndCell() throws {
        let def = try PetDefinition.decode(from: Data(legacyClaudeCodeJSON.utf8))
        let atlas = try XCTUnwrap(def.atlas2d)
        XCTAssertEqual(atlas.atlasPixelSize, CGSize(width: 1536, height: 1872))
    }

    func test_textureRect_flipsForBottomLeftOrigin() throws {
        let def = try PetDefinition.decode(from: Data(legacyClaudeCodeJSON.utf8))
        let atlas = try XCTUnwrap(def.atlas2d)
        let state = try XCTUnwrap(atlas.states["sleep"]) // row 7
        let h = atlas.atlasPixelSize.height // 1872
        // top-left rect: y = 7*208 = 1456, maxY = 1664.
        // bottom-left y = 1872 - 1664 = 208.
        let tex = atlas.textureRect(state: state, frame: 0, atlasPixelHeight: h)
        XCTAssertEqual(tex, CGRect(x: 0, y: 208, width: 192, height: 208))
    }

    func test_defaultForm_prefersAtlas() throws {
        let def = try PetDefinition.decode(from: Data(modernPetdefJSON.utf8))
        XCTAssertEqual(def.defaultForm, .atlas2d(imageName: "sprite.png"))
    }

    func test_bundledModelPetResolvesItsGLBResource() throws {
        let def = try XCTUnwrap(PetDefinition.loadBundled(id: "founder-gates"))
        let model = try XCTUnwrap(def.model3d)

        let url = try XCTUnwrap(PetModelResourceLocator.url(for: model.glb, petID: def.id))

        XCTAssertEqual(url.lastPathComponent, "founder-gates-actions.glb")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_bundledFounderModelPetsResolveDistinctGLBResources() throws {
        var resolved = Set<URL>()
        for id in bundledFounderIDs {
            let def = try XCTUnwrap(PetDefinition.loadBundled(id: id), id)
            let model = try XCTUnwrap(def.model3d, id)
            let url = try XCTUnwrap(PetModelResourceLocator.url(for: model.glb, petID: def.id), id)

            XCTAssertEqual(url.lastPathComponent, "\(id)-actions.glb", id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), id)
            XCTAssertTrue(resolved.insert(url).inserted, "duplicate GLB URL for \(id)")
        }
    }

    func test_bundledModelPetCatalogIncludesCurrentImagineCast() throws {
        let ids = bundledModelPetIDs()

        XCTAssertGreaterThanOrEqual(ids.count, minimumSyncedModelPetCount)
        XCTAssertTrue(ids.contains("curie"))
        XCTAssertTrue(ids.contains("einstein"))
        XCTAssertTrue(ids.contains("founder-gates"))
        XCTAssertTrue(ids.contains("kawaii-aurora-fox"))

        var groupCounts: [String: Int] = [:]
        for id in ids {
            let def = try XCTUnwrap(PetDefinition.loadBundled(id: id), id)
            let group = try XCTUnwrap(def.group, id)
            groupCounts[group, default: 0] += 1
        }

        XCTAssertEqual(groupCounts["Founders"], 9)
        XCTAssertGreaterThanOrEqual(groupCounts["Legends"] ?? 0, 40)
        XCTAssertGreaterThanOrEqual(groupCounts["Kawaii Animals"] ?? 0, 20)
    }

    func test_model3DAvailableSemanticClipsIncludesCompatibilityAliases() throws {
        let def = try XCTUnwrap(PetDefinition.loadBundled(id: "founder-gates"))
        let model = try XCTUnwrap(def.model3d)

        XCTAssertTrue(model.availableSemanticClips.contains("idle"))
        XCTAssertTrue(model.availableSemanticClips.contains("think"))
        XCTAssertTrue(model.availableSemanticClips.contains("success"))
        XCTAssertTrue(model.availableSemanticClips.contains("clean"))
    }

    @MainActor
    func test_defaultGLBSceneLoaderLoadsBundledFounderModel() throws {
        let def = try XCTUnwrap(PetDefinition.loadBundled(id: "founder-gates"))
        let model = try XCTUnwrap(def.model3d)
        let url = try XCTUnwrap(PetModelResourceLocator.url(for: model.glb, petID: def.id))

        let scene = DefaultGLBSceneLoader().loadScene(
            at: url,
            clipNames: Array(model.availableSemanticClips)
        )

        XCTAssertNotNil(scene)
        XCTAssertFalse(scene?.rootNode.childNodes.isEmpty ?? true)
    }

    @MainActor
    func test_defaultGLBSceneLoaderAttachesAnimationPlayers() throws {
        // Fix: the loader must surface GLTFKit2's per-clip SCNAnimationPlayers
        // (previously dropped), so the pet can actually animate. They are attached
        // to the scene root keyed by clip name.
        let def = try XCTUnwrap(PetDefinition.loadBundled(id: "founder-gates"))
        let model = try XCTUnwrap(def.model3d)
        let url = try XCTUnwrap(PetModelResourceLocator.url(for: model.glb, petID: def.id))
        let scene = try XCTUnwrap(DefaultGLBSceneLoader().loadScene(at: url, clipNames: []))
        XCTAssertFalse(scene.rootNode.animationKeys.isEmpty,
                       "founder model should expose its glTF clips as attached animation players")
    }

    @MainActor
    func test_defaultGLBSceneLoaderLoadsEveryBundledModel() throws {
        let loader = DefaultGLBSceneLoader()
        let ids = bundledModelPetIDs()
        XCTAssertGreaterThanOrEqual(ids.count, minimumSyncedModelPetCount)

        for id in ids {
            let def = try XCTUnwrap(PetDefinition.loadBundled(id: id), id)
            let model = try XCTUnwrap(def.model3d, id)
            let url = try XCTUnwrap(PetModelResourceLocator.url(for: model.glb, petID: def.id), id)

            let scene = loader.loadScene(at: url, clipNames: Array(model.availableSemanticClips))

            XCTAssertNotNil(scene, id)
            XCTAssertFalse(scene?.rootNode.childNodes.isEmpty ?? true, id)
        }
    }

    @MainActor
    func test_sceneKitRendererMountsFounderModelWithAppCameraAndInteractionState() throws {
        UserDefaults.standard.removeObject(forKey: "pet.model3d.yaw.founder-gates")
        UserDefaults.standard.removeObject(forKey: "pet.model3d.scale.founder-gates")

        let def = try XCTUnwrap(PetDefinition.loadBundled(id: "founder-gates"))
        let form = try XCTUnwrap(def.defaultForm)
        let renderer = SceneKitPetRenderer(definition: def, form: form)
        let container = NSView(frame: CGRect(origin: .zero, size: PetPanel.defaultSize))

        renderer.mount(in: container)
        renderer.rotateModel(by: .pi / 4, persist: false)
        renderer.resizeModel(by: 1.25, persist: false)

        let sceneView = try XCTUnwrap(renderer.view as? SCNView)
        XCTAssertEqual(sceneView.pointOfView?.name, "pet.camera")
        XCTAssertNotNil(sceneView.scene)
        XCTAssertGreaterThan(renderer.interactionState.scale, 1)
        XCTAssertNotEqual(renderer.interactionState.yawRadians, 0)

        renderer.unmount()
    }

    @MainActor
    func test_sceneKitRendererFramesEveryBundledModelIntoVisiblePanel() throws {
        let ids = bundledModelPetIDs()
        XCTAssertGreaterThanOrEqual(ids.count, minimumSyncedModelPetCount)

        for id in ids {
            autoreleasepool {
                guard let def = PetDefinition.loadBundled(id: id) else {
                    XCTFail("missing petdef for \(id)")
                    return
                }
                guard let form = def.defaultForm else {
                    XCTFail("missing default form for \(id)")
                    return
                }

                let renderer = SceneKitPetRenderer(definition: def, form: form)
                let container = NSView(frame: CGRect(origin: .zero, size: PetPanel.defaultSize))
                renderer.mount(in: container)
                defer { renderer.unmount() }

                guard let metrics = renderer.frameMetricsForTesting else {
                    XCTFail("missing frame metrics for \(id)")
                    return
                }

                XCTAssertGreaterThan(metrics.sourceMaxExtent, 0, id)
                XCTAssertGreaterThan(metrics.baseScale, 0, id)
                XCTAssertEqual(metrics.normalizedMaxExtent, 2.0, accuracy: 0.01, id)
            }
        }
    }

    /// Regression: every bundled 3D pet must launch upright (longest dimension
    /// vertical, +Y). This guards against exports authored on their side/back,
    /// which currently render as soles/feet toward the camera instead of face
    /// and full body.
    @MainActor
    func test_sceneKitRendererLaunchesEveryModelPetUpright() throws {
        let ids = bundledModel3DPetIDs()
        XCTAssertFalse(ids.isEmpty, "expected bundled 3D pets")

        for id in ids {
            autoreleasepool {
                guard let def = PetDefinition.loadBundled(id: id) else {
                    XCTFail("missing petdef for \(id)")
                    return
                }
                guard let form = def.defaultForm else {
                    XCTFail("missing default form for \(id)")
                    return
                }

                let renderer = SceneKitPetRenderer(definition: def, form: form)
                let container = NSView(frame: CGRect(origin: .zero, size: PetPanel.defaultSize))
                renderer.mount(in: container)
                defer { renderer.unmount() }

                XCTAssertTrue(
                    renderer.isUprightForTesting,
                    "\(id) did not launch upright — likely rendered on its side/back"
                )
            }
        }
    }

    /// Regression: skinned founder models specifically must be upright at mount
    /// BEFORE any user interaction (click/chat). The skeleton bind-pose can
    /// orient the skinned mesh horizontally even though the raw mesh geometry
    /// is Y-dominant. This test pumps the render loop so the presentation-time
    /// orientation correction fires, then verifies the presentation bounding
    /// box is Y-dominant. Guards the "soles of feet until clicked" failure.
    @MainActor
    func test_skinnedFoundersAreUprightBeforeInteraction() throws {
        let ids = ["founder-gates", "founder-zuckerberg", "founder-jobs", "founder-musk"]
        for id in ids {
            try autoreleasepool {
                let def = try XCTUnwrap(PetDefinition.loadBundled(id: id), id)
                let form = try XCTUnwrap(def.defaultForm, id)
                let renderer = SceneKitPetRenderer(definition: def, form: form)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 256, height: 256),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                let container = NSView(frame: NSRect(x: 0, y: 0, width: 256, height: 256))
                window.contentView = container
                renderer.mount(in: container)
                defer { renderer.unmount(); window.orderOut(nil) }

                // Pump the render loop so the presentation-time orientation
                // correction and camera reframe fire (3 passes, one per render).
                let scnView = try XCTUnwrap(renderer.view as? SCNView)
                scnView.frame = container.bounds
                container.layoutSubtreeIfNeeded()
                for _ in 0..<3 {
                    _ = scnView.snapshot()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }

                XCTAssertTrue(
                    renderer.isUprightForTesting,
                    "\(id) was not upright after mount — skeleton bind pose orients it horizontally"
                )
            }
        }
    }

    /// Pixel-truth: a representative set of 3D pets renders with face + body
    /// visible, not just feet/soles toward the camera. Guards the "launch
    /// upright" requirement with a real rasterization check.
    @MainActor
    func test_sceneKitRendererShowsFaceAndBodyNotJustFeet() throws {
        let ids = ["founder-gates", "founder-zuckerberg", "newton", "go-gopher"]
        for id in ids {
            try autoreleasepool {
                let def = try XCTUnwrap(PetDefinition.loadBundled(id: id), id)
                let form = try XCTUnwrap(def.defaultForm, id)
                let renderer = SceneKitPetRenderer(definition: def, form: form)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 256, height: 256),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                let container = NSView(frame: NSRect(x: 0, y: 0, width: 256, height: 256))
                window.contentView = container
                renderer.mount(in: container)
                renderer.setPaused(false)
                renderer.play(state: "idle")
                defer { renderer.unmount(); window.orderOut(nil) }

                let scnView = try XCTUnwrap(renderer.view as? SCNView)
                scnView.frame = container.bounds
                container.layoutSubtreeIfNeeded()
                _ = scnView.snapshot()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))

                let image = scnView.snapshot()
                let tiff = try XCTUnwrap(image.tiffRepresentation, id)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff), id)
                let w = bitmap.pixelsWide
                let h = bitmap.pixelsHigh

                var top = 0, middle = 0, bottom = 0
                for y in stride(from: 0, to: h, by: 4) {
                    for x in stride(from: 0, to: w, by: 4) {
                        guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.05 else { continue }
                        if y < h / 3 {
                            top += 1
                        } else if y < 2 * h / 3 {
                            middle += 1
                        } else {
                            bottom += 1
                        }
                    }
                }

                XCTAssertGreaterThan(top, 0, "\(id) head/face not visible")
                XCTAssertGreaterThan(middle, top / 4, "\(id) body missing or tiny")
                XCTAssertGreaterThan(bottom, 0, "\(id) feet/legs not visible")
                // If bottom dominates top, the pet is likely feet-first / on its back.
                XCTAssertGreaterThan(top, bottom / 3, "\(id) rendered feet-first (soles toward camera)")
            }
        }
    }

    /// Pixel-truth: a mounted founder model must actually rasterize visible
    /// (non-transparent) pixels. The framing test proves the scene-graph math;
    /// this proves SceneKit draws something, catching invisible-render bugs
    /// (back-face culling, fully-transparent materials, mis-aimed camera) that
    /// leave the panel blank even though loading + framing succeed.
    @MainActor
    func test_sceneKitRendererRasterizesVisiblePixelsForFounderModel() throws {
        let def = try XCTUnwrap(PetDefinition.loadBundled(id: "founder-gates"))
        let form = try XCTUnwrap(def.defaultForm)
        let renderer = SceneKitPetRenderer(definition: def, form: form)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 256, height: 256),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 256, height: 256))
        window.contentView = container
        renderer.mount(in: container)
        renderer.setPaused(false)
        renderer.play(state: "idle")
        defer { renderer.unmount() }

        let scnView = try XCTUnwrap(renderer.view as? SCNView)
        scnView.frame = container.bounds
        container.layoutSubtreeIfNeeded()
        // The model is framed against its post-skinning presentation bounds on the
        // first render (see SceneKitPetRenderer.frameCameraToPresentation), so kick
        // a render and let that reframe land before sampling.
        _ = scnView.snapshot()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let image = scnView.snapshot()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let w = bitmap.pixelsWide
        let h = bitmap.pixelsHigh
        var opaquePixels = 0
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    opaquePixels += 1
                }
            }
        }
        XCTAssertGreaterThan(
            opaquePixels, 0,
            "founder-gates rendered 0 visible pixels in a \(w)x\(h) snapshot — scene loads + frames but does not rasterize."
        )
    }

    /// TEMP: save the live render of a founder in the real transparent PetPanel
    /// so the result can be eyeballed. Removed after review.
    /// TEMP: compare bind-pose vs presentation (skinned) bounds per model to
    /// explain why skinned founders mis-frame while go-gopher frames fine.
    /// TEMP: save the live render of each model in the real transparent PetPanel
    /// AFTER the presentation-framing reframe lands, so the result can be eyeballed.
    /// Guards the founder fix: a skinned founder rig deforms ~100x beyond its
    /// bind-pose bounds once the skinner runs, so the camera must re-fit to the
    /// presentation bounds (see `frameCameraToPresentation`). Before the fix the
    /// founder rendered blank or as edge fragments; assert the pet is actually
    /// visible AND centered after the reframe lands.
    @MainActor
    func test_skinnedFounderRendersCenteredAfterPresentationReframe() throws {
        let def = try XCTUnwrap(PetDefinition.loadBundled(id: "founder-zuckerberg"))
        let form = try XCTUnwrap(def.defaultForm)
        let renderer = SceneKitPetRenderer(definition: def, form: form)
        let panel = PetPanel()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 192, height: 208))
        panel.contentView = content
        renderer.mount(in: content)
        panel.orderFrontRegardless()
        renderer.play(state: "idle")
        defer { renderer.unmount(); panel.orderOut(nil) }

        let scn = try XCTUnwrap(renderer.view as? SCNView)
        scn.frame = content.bounds
        content.layoutSubtreeIfNeeded()
        _ = scn.snapshot() // first render → schedules the presentation reframe
        RunLoop.current.run(until: Date().addingTimeInterval(0.5)) // let the reframe land

        let img = scn.snapshot()
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let bmp = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let w = bmp.pixelsWide, h = bmp.pixelsHigh
        var total = 0, center = 0
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                guard let c = bmp.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                total += 1
                if x > w / 4, x < 3 * w / 4, y > h / 4, y < 3 * h / 4 { center += 1 }
            }
        }
        XCTAssertGreaterThan(total, 200, "founder rendered no/too-few visible pixels")
        XCTAssertGreaterThan(center, 50, "founder not framed in the centre (edge fragments / mis-framed)")
    }

    /// Regression (bird's-eye-on-chat): the pet camera must frame the model ONCE
    /// (after the skinner settles) and then stay PUT — it must not re-aim itself on
    /// every pose change. Clicking a pet to chat drives it `idle → listen`; the old
    /// per-pose reframe re-ran presentation framing against an unsettled skinned
    /// pose, snapping the camera for a frame and reading as a top-of-head / bird's-
    /// eye view. The camera is always built level (position at the bounding-sphere
    /// centre, `look(at:)` the same centre → worldFront ≈ (0,0,-1)); the only way it
    /// can lurch is by re-aiming. So: assert the camera is level after idle, then
    /// assert a pose change leaves its world transform (and levelness) UNCHANGED.
    @MainActor
    func test_petCameraDoesNotReaimOnPoseChange() throws {
        let def = try XCTUnwrap(PetDefinition.loadBundled(id: "founder-zuckerberg"))
        let form = try XCTUnwrap(def.defaultForm)
        let renderer = SceneKitPetRenderer(definition: def, form: form)
        let panel = PetPanel()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 192, height: 208))
        panel.contentView = content
        renderer.mount(in: content)
        panel.orderFrontRegardless()
        renderer.play(state: "idle")
        defer { renderer.unmount(); panel.orderOut(nil) }

        let scn = try XCTUnwrap(renderer.view as? SCNView)
        scn.frame = content.bounds
        content.layoutSubtreeIfNeeded()

        func settle() {
            _ = scn.snapshot() // kick a render so the async one-shot reframe Task can land
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        func camera() throws -> SCNNode {
            try XCTUnwrap(scn.scene?.rootNode.childNode(withName: "pet.camera", recursively: true))
        }

        // 1. Idle settles → camera framed and LEVEL (never looking down).
        settle()
        let idleCam = try camera()
        let idleTransform = idleCam.simdWorldTransform
        let idleFront = idleCam.simdWorldFront
        XCTAssertEqual(Double(idleFront.y), 0, accuracy: 0.05,
                       "idle camera is not level (looking up/down) — front.y=\(idleFront.y)")

        // 2. Chat opens → pet is driven to `listen`. The camera must NOT re-aim.
        renderer.play(state: "listen")
        settle()
        let listenCam = try camera()
        let listenFront = listenCam.simdWorldFront
        XCTAssertEqual(Double(listenFront.y), 0, accuracy: 0.05,
                       "listen camera is not level (bird's-eye) — front.y=\(listenFront.y)")

        // World transform unchanged: the camera framed once and stayed put.
        let a = idleTransform, b = listenCam.simdWorldTransform
        for col in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(
                    Double(a[col][row]), Double(b[col][row]), accuracy: 0.001,
                    "camera re-aimed on idle→listen (col \(col), row \(row)) — it must frame once and stay put"
                )
            }
        }
    }

    /// Guard against the Imagine sync (or a bad commit) regressing the founder
    /// avatars to low-poly placeholders (~1.3k verts) instead of the real
    /// high-poly models (~100k verts), which render as faceted, blank-faced blobs.
    /// The sync is opt-in (committed models are the source of truth); this fails
    /// CI if a low-poly founder ever lands.
    func test_founderModelsAreHighPolyNotPlaceholders() throws {
        let minVertices = 20_000
        for id in bundledFounderIDs {
            let def = try XCTUnwrap(PetDefinition.loadBundled(id: id), id)
            let model = try XCTUnwrap(def.model3d, id)
            let url = try XCTUnwrap(PetModelResourceLocator.url(for: model.glb, petID: id), id)
            let verts = try Self.glbPositionCount(at: url)
            XCTAssertGreaterThan(
                verts, minVertices,
                "\(id) is low-poly (\(verts) verts) — likely a synced placeholder. Founders must ship the high-poly models."
            )
        }
    }

    @MainActor
    func test_petCatalogFiltered_searchAndCategoryAndSort() throws {
        let defs = PetCatalog.bundledDefinitions()
        try XCTSkipIf(defs.count < 10, "needs the bundled pet catalog")

        // Category scoping.
        let founders = PetCatalog.filtered(defs, search: "", category: "Founders")
        XCTAssertFalse(founders.isEmpty)
        XCTAssertTrue(founders.allSatisfy { PetCatalog.groupName(for: $0) == "Founders" })

        // Case-insensitive search by display name.
        let gates = PetCatalog.filtered(defs, search: "GaTeS", category: nil)
        XCTAssertTrue(gates.contains { PetCatalog.displayName(for: $0).lowercased().contains("gates") })

        // No match → empty.
        XCTAssertTrue(PetCatalog.filtered(defs, search: "zzz-not-a-pet", category: nil).isEmpty)

        // Stable alphabetical sort.
        let names = founders.map { PetCatalog.displayName(for: $0) }
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        // Category chips are non-empty and counted.
        let categories = PetCatalog.categories(defs)
        XCTAssertTrue(categories.contains { $0.name == "Founders" && $0.count >= 1 })
    }

    /// Regression: build 45 (#769) shipped a `PetFormPickerView` that SIGSEGV'd
    /// in `swift::RefCounts` ("outlined init with copy of PetFormPickerView")
    /// the moment the Pets settings section rendered. Host the real view, pump
    /// the run loop so SwiftUI's AttributeGraph evaluates the body + LazyVGrid,
    /// and force a draw — the same path that crashed on the desktop. If the
    /// picker constructs and renders without trapping, the regression is closed.
    @MainActor
    func test_petFormPickerView_hostsAndRendersWithoutCrash() throws {
        let definitions = PetCatalog.bundledDefinitions()
        XCTAssertFalse(definitions.isEmpty, "expected bundled pets for the picker")

        var selected = definitions.first?.id ?? ""
        let binding = Binding<String>(get: { selected }, set: { selected = $0 })
        var lastSelected: (String, PetForm)?
        let view = PetFormPickerView(definitions: definitions, selectedPetID: binding) { id, form in
            lastSelected = (id, form)
        }

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 620)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        // Pump so AttributeGraph evaluates the view tree and the lazy grid
        // materializes its visible cells (where the copy/retain crash fired).
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }

        XCTAssertNotNil(host.window, "picker should host without trapping")
        _ = lastSelected
    }

    /// Read a binary glTF's first-mesh POSITION accessor count (vertex count)
    /// straight from the JSON chunk — no decode needed.
    private static func glbPositionCount(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard data.count > 20 else { return 0 }
        let b = [UInt8](data[12..<16])
        let jsonLength = Int(UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24))
        guard data.count >= 20 + jsonLength else { return 0 }
        let json = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<(20 + jsonLength))) as? [String: Any]
        let accessors = json?["accessors"] as? [[String: Any]] ?? []
        let meshes = json?["meshes"] as? [[String: Any]] ?? []
        guard let primitive = (meshes.first?["primitives"] as? [[String: Any]])?.first,
              let attributes = primitive["attributes"] as? [String: Any],
              let positionIndex = attributes["POSITION"] as? Int,
              positionIndex < accessors.count,
              let count = accessors[positionIndex]["count"] as? Int else { return 0 }
        return count
    }

    func test_petWindowState_roundTripsFrame() {
        let id = "test-window-pet"
        defer { UserDefaults.standard.removeObject(forKey: "pet.window.frame." + id) }
        UserDefaults.standard.removeObject(forKey: "pet.window.frame." + id)
        XCTAssertNil(PetWindowState.storedFrame(for: id))
        PetWindowState.store(NSRect(x: 120, y: 340, width: 260, height: 281), for: id)
        let restored = PetWindowState.storedFrame(for: id)
        XCTAssertEqual(restored?.origin.x, 120)
        XCTAssertEqual(restored?.origin.y, 340)
        XCTAssertEqual(restored?.width, 260)
        XCTAssertEqual(restored?.height, 281)
    }

    @MainActor
    func test_resizePanel_growsClampedAndAspectLocked() throws {
        let def = try XCTUnwrap(PetDefinition.loadBundled(id: "founder-gates"))
        let form = try XCTUnwrap(def.defaultForm)
        let renderer = SceneKitPetRenderer(definition: def, form: form)
        let panel = PetPanel()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 192, height: 208))
        panel.contentView = content
        renderer.mount(in: content)
        panel.orderFrontRegardless()
        defer { renderer.unmount(); panel.orderOut(nil) }

        let startWidth = panel.frame.width
        renderer.resizePanel(by: 1.5)
        XCTAssertGreaterThan(panel.frame.width, startWidth, "panel should grow")
        XCTAssertEqual(panel.frame.height / panel.frame.width, 208.0 / 192.0, accuracy: 0.01,
                       "aspect ratio should stay locked")

        for _ in 0..<20 { renderer.resizePanel(by: 2) }
        XCTAssertLessThanOrEqual(panel.frame.width, 561, "should clamp at max width")
        for _ in 0..<30 { renderer.resizePanel(by: 0.5) }
        XCTAssertGreaterThanOrEqual(panel.frame.width, 109, "should clamp at min width")
    }

    @MainActor
    func test_setPetRebuildsRendererWithSelectedModelDefinition() throws {
        let initial = try PetDefinition.decode(from: Data(modernPetdefJSON.utf8))
        let model = try XCTUnwrap(PetDefinition.loadBundled(id: "founder-gates"))
        let modelForm = try XCTUnwrap(model.defaultForm)
        let controller = PetCompanionController()
        var factoryInputs: [(String, PetForm)] = []
        controller.rendererFactory = { definition, form in
            factoryInputs.append((definition.id, form))
            return StubRenderer(definition: definition, form: form)
        }

        controller.start(with: initial)
        controller.setPet(model, form: modelForm)

        XCTAssertEqual(factoryInputs.last?.0, "founder-gates")
        XCTAssertEqual(factoryInputs.last?.1, .model3d(glbName: "founder-gates-actions.glb"))
    }

    func test_roundTripEncodeDecode() throws {
        let def = try PetDefinition.decode(from: Data(modernPetdefJSON.utf8))
        let encoded = try JSONEncoder().encode(def)
        let again = try PetDefinition.decode(from: encoded)
        XCTAssertEqual(again.id, def.id)
        XCTAssertEqual(again.atlas2d?.states["work"]?.hero, true)
        XCTAssertEqual(again.behavior?.transitions.first?.when, .cooldownElapsed)
    }

    func test_settingsSidebarExposesPetCompanionTab() {
        XCTAssertTrue(SettingsTab.visibleTabs.contains(.pets))
        XCTAssertEqual(SettingsTab.pets.title, "Pets")
        XCTAssertEqual(SettingsTab.pets.icon, "pawprint.fill")
    }

    func test_settingsManifestExposesPetCompanionControls() throws {
        let item = try XCTUnwrap(SettingsManifest.all.first { $0.id == "pets.companion" })

        XCTAssertEqual(item.tab, .pets)
        XCTAssertEqual(item.pageRoute, .petsRoot)
        XCTAssertEqual(item.anchorID, SettingsAnchor.petsCompanion)
        XCTAssertTrue(SettingsManifest.visibleAnchorIDs.contains(SettingsAnchor.petsCompanion))
    }

}
