using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates.Moire;

namespace OpenBurnBar.Particles.Substrates.Families;

/// <summary>
/// Moiré family registry — C# port of Swift <c>Families/MoireFamily.swift</c>.
/// Interference-pattern line fields / thin-film sheens: blooming fringes, faceted
/// crystal lattices, ruled gratings, and soap-film bubbles. Ids / labels / accents
/// mirror the Swift descriptors byte-for-byte.
/// </summary>
public static class MoireFamily
{
    public static readonly SubstrateDescriptor[] Styles =
    {
        new SubstrateDescriptor(
            id: "moire.fringe-bloom", family: SubstrateFamily.Moire,
            label: "Fringe Bloom", hint: "fringes",
            accent: new Rgba(188 / 255.0, 208 / 255.0, 1.0),
            accent2: new Rgba(150 / 255.0, 150 / 255.0, 1.0),
            make: () => new FringeBloomSubstrate()),
        new SubstrateDescriptor(
            id: "moire.lattice-facet", family: SubstrateFamily.Moire,
            label: "Lattice Facet", hint: "crystal",
            accent: new Rgba(170 / 255.0, 200 / 255.0, 1.0),
            accent2: new Rgba(200 / 255.0, 180 / 255.0, 1.0),
            make: () => new LatticeFacetSubstrate()),
        new SubstrateDescriptor(
            id: "moire.ruling-grating", family: SubstrateFamily.Moire,
            label: "Ruling Grating", hint: "gratings",
            accent: new Rgba(200 / 255.0, 210 / 255.0, 1.0),
            accent2: new Rgba(160 / 255.0, 170 / 255.0, 1.0),
            make: () => new RulingGratingSubstrate()),
        new SubstrateDescriptor(
            id: "moire.film-bubble", family: SubstrateFamily.Moire,
            label: "Film Bubble", hint: "bubbles",
            accent: new Rgba(180 / 255.0, 220 / 255.0, 1.0),
            accent2: new Rgba(220 / 255.0, 190 / 255.0, 1.0),
            make: () => new FilmBubbleSubstrate()),
    };
}
