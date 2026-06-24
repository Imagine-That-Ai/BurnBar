import XCTest
@testable import OpenBurnBar

/// Pet prop schema mirror: the `props[]` on a 3D form decodes from the SAME petdef
/// JSON the web reads, the scale union (number | array) normalizes to 3 components,
/// the socket resolver mirrors petcore, and per-state visibility honors the contract.
final class PetPropTests: XCTestCase {

    private func decodePetdef(_ json: String) throws -> PetDefinition {
        try JSONDecoder().decode(PetDefinition.self, from: Data(json.utf8))
    }

    func testModel3dFormDecodesProps() throws {
        let def = try decodePetdef(#"""
        {
          "schema": "petdef/1",
          "id": "founder-jobs",
          "name": "founder-jobs",
          "kind": "model3d",
          "forms": [{
            "kind": "model3d",
            "modelKind": "rigged",
            "glb": "founder-jobs-actions.glb",
            "clips": { "idle": "idle", "clean": "clean" },
            "clipNames": ["idle", "clean"],
            "props": [{
              "id": "push-broom",
              "glb": "push-broom.glb",
              "socket": "rightHand",
              "transform": { "position": [0, 0.02, 0.04], "rotationEuler": [1.5708, 0, 0], "scale": 0.32 },
              "visibleStates": ["clean", "scoop"],
              "hiddenStates": ["sleep"],
              "label": "Push Broom"
            }]
          }]
        }
        """#)

        let props = try XCTUnwrap(def.model3d?.props)
        XCTAssertEqual(props.count, 1)
        let p = props[0]
        XCTAssertEqual(p.id, "push-broom")
        XCTAssertEqual(p.glb, "push-broom.glb")
        XCTAssertEqual(p.socket, "rightHand")
        XCTAssertEqual(p.label, "Push Broom")
        XCTAssertEqual(p.transform?.position, [0, 0.02, 0.04])
        XCTAssertEqual(p.transform?.scale, [0.32, 0.32, 0.32], "a JSON-number scale normalizes to 3 components")
        XCTAssertEqual(p.visibleStates, ["clean", "scoop"])
        XCTAssertEqual(p.hiddenStates, ["sleep"])
    }

    func testPropsAbsentIsBackCompatible() throws {
        let def = try decodePetdef(#"""
        { "schema": "petdef/1", "id": "x", "name": "x", "kind": "model3d",
          "forms": [{ "kind": "model3d", "modelKind": "rigged", "glb": "x.glb", "clips": { "idle": "idle" } }] }
        """#)
        XCTAssertNil(def.model3d?.props)
    }

    func testScaleAcceptsArray() throws {
        let t = try JSONDecoder().decode(
            PetDefinition.PetPropTransform.self,
            from: Data(#"{ "scale": [1, 2, 3] }"#.utf8))
        XCTAssertEqual(t.scale, [1, 2, 3])
    }

    func testResolveSocketBone() {
        let rig: Set<String> = ["Hips", "Spine", "Spine1", "Spine2", "Head", "LeftHand", "RightHand"]
        XCTAssertEqual(PetDefinition.PetProp.resolveSocketBone("rightHand", available: rig), "RightHand")
        XCTAssertEqual(PetDefinition.PetProp.resolveSocketBone("head", available: rig), "Head")
        XCTAssertEqual(PetDefinition.PetProp.resolveSocketBone("spine", available: rig), "Spine2", "prefers the most specific spine")
        XCTAssertEqual(PetDefinition.PetProp.resolveSocketBone("RightHand", available: rig), "RightHand", "unknown alias falls back to literal bone")
        XCTAssertNil(PetDefinition.PetProp.resolveSocketBone("root", available: rig), "root attaches to content root, not a bone")
        XCTAssertNil(PetDefinition.PetProp.resolveSocketBone("Tail", available: rig))
        XCTAssertNil(PetDefinition.PetProp.resolveSocketBone("leftHand", available: ["RightHand"]))
    }

    func testPropVisibility() {
        let gated = PetDefinition.PetProp(
            id: "broom", glb: "b.glb", socket: "rightHand", transform: nil,
            visibleStates: ["clean", "scoop"], hiddenStates: ["sleep"], label: nil)
        XCTAssertTrue(gated.isVisible(in: "clean"))
        XCTAssertFalse(gated.isVisible(in: "idle"), "not in visibleStates")
        XCTAssertFalse(gated.isVisible(in: "sleep"), "hiddenStates always wins")

        let always = PetDefinition.PetProp(
            id: "hat", glb: "h.glb", socket: "head", transform: nil,
            visibleStates: nil, hiddenStates: ["sleep"], label: nil)
        XCTAssertTrue(always.isVisible(in: "idle"))
        XCTAssertFalse(always.isVisible(in: "sleep"))
    }
}
