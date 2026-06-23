import AppKit
import XCTest
@testable import OpenBurnBar

/// C2 — decodes a real `petdef.json` (the shipped `claudecode` legacy `pet.json`
/// plus the modern `petdef/1` superset) and proves the Swift frame-rect helper
/// matches the shared TS math (192×208 cells, anchor 96/196).
final class PetDefinitionTests: XCTestCase {

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
