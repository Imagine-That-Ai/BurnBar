import Foundation
import OpenBurnBarKernel

/// Iridescent Mesh family substrate registry. Ported from imaginethat
/// `glyph/stage/styles/mesh/`.
enum MeshFamily {
    static let styles: [SubstrateDescriptor] = [
        SubstrateDescriptor(
            id: "mesh.mesh-caustic", family: .mesh,
            label: "Caustic Pool", hint: "caustics",
            accent: RGBA(r: 1.0, g: 120/255, b: 180/255), accent2: RGBA(r: 130/255, g: 220/255, b: 1.0),
            make: { MeshCausticSubstrate() }),
        SubstrateDescriptor(
            id: "mesh.mesh-patch", family: .mesh,
            label: "Gradient Patch", hint: "patches",
            accent: RGBA(r: 1.0, g: 140/255, b: 190/255), accent2: RGBA(r: 1.0, g: 186/255, b: 140/255),
            make: { MeshPatchSubstrate() }),
        SubstrateDescriptor(
            id: "mesh.mesh-isoline", family: .mesh,
            label: "Iso Contour", hint: "contours",
            accent: RGBA(r: 1.0, g: 150/255, b: 200/255), accent2: RGBA(r: 200/255, g: 200/255, b: 1.0),
            make: { MeshIsolineSubstrate() }),
        SubstrateDescriptor(
            id: "mesh.mesh-grain", family: .mesh,
            label: "Living Grain", hint: "grain",
            accent: RGBA(r: 1.0, g: 160/255, b: 170/255), accent2: RGBA(r: 1.0, g: 200/255, b: 150/255),
            make: { MeshGrainSubstrate() })
    ]
}
