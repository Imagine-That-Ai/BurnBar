using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates.Mesh;

namespace OpenBurnBar.Particles.Substrates.Families;

/// <summary>
/// Iridescent Mesh family registry — C# port of Swift <c>Families/MeshFamily.swift</c>.
/// Connected-node lattices / caustic light nets: refracted caustic pools, stained-glass
/// gradient patches, iso-contour fields, and living film grain. Ids / labels / accents
/// mirror the Swift descriptors byte-for-byte.
/// </summary>
public static class MeshFamily
{
    public static readonly SubstrateDescriptor[] Styles =
    {
        new SubstrateDescriptor(
            id: "mesh.mesh-caustic", family: SubstrateFamily.Mesh,
            label: "Caustic Pool", hint: "caustics",
            accent: new Rgba(1.0, 120 / 255.0, 180 / 255.0),
            accent2: new Rgba(130 / 255.0, 220 / 255.0, 1.0),
            make: () => new MeshCausticSubstrate()),
        new SubstrateDescriptor(
            id: "mesh.mesh-patch", family: SubstrateFamily.Mesh,
            label: "Gradient Patch", hint: "patches",
            accent: new Rgba(1.0, 140 / 255.0, 190 / 255.0),
            accent2: new Rgba(1.0, 186 / 255.0, 140 / 255.0),
            make: () => new MeshPatchSubstrate()),
        new SubstrateDescriptor(
            id: "mesh.mesh-isoline", family: SubstrateFamily.Mesh,
            label: "Iso Contour", hint: "contours",
            accent: new Rgba(1.0, 150 / 255.0, 200 / 255.0),
            accent2: new Rgba(200 / 255.0, 200 / 255.0, 1.0),
            make: () => new MeshIsolineSubstrate()),
        new SubstrateDescriptor(
            id: "mesh.mesh-grain", family: SubstrateFamily.Mesh,
            label: "Living Grain", hint: "grain",
            accent: new Rgba(1.0, 160 / 255.0, 170 / 255.0),
            accent2: new Rgba(1.0, 200 / 255.0, 150 / 255.0),
            make: () => new MeshGrainSubstrate()),
    };
}
