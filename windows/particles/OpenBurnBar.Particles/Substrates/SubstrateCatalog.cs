using System;
using System.Collections.Generic;
using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates.Mesh;
using OpenBurnBar.Particles.Substrates.Moire;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// Static metadata for one substrate style + a factory to build its painter —
/// C# port of the Swift Core <c>SubstrateDescriptor</c>
/// (<c>Views/Substrate/SubstrateCatalog.swift</c>). The Windows host resolves the
/// selected id to a descriptor and calls <see cref="Make"/> once (the painter is
/// cached + reused across frames by the renderer host).
/// </summary>
public sealed class SubstrateDescriptor
{
    /// <summary>Globally-unique id: <c>"plain"</c> or <c>"&lt;family&gt;.&lt;style&gt;"</c> (persisted).</summary>
    public string Id { get; }
    public SubstrateFamily Family { get; }
    public string Label { get; }
    public string Hint { get; }
    public Rgba Accent { get; }
    public Rgba Accent2 { get; }
    public Func<ISwarmSubstrate> Make { get; }

    public SubstrateDescriptor(string id, SubstrateFamily family, string label, string hint,
        in Rgba accent, in Rgba accent2, Func<ISwarmSubstrate> make)
    {
        Id = id;
        Family = family;
        Label = label;
        Hint = hint;
        Accent = accent;
        Accent2 = accent2;
        Make = make;
    }
}

/// <summary>
/// The Windows substrate registry — the C# analog of the Swift Core
/// <c>SubstrateCatalog</c>. This port ships the shared <c>plain</c> descriptor plus
/// the two families landed by this lane (Mesh + Moiré, 4 bespoke each); the
/// Constellation family's Starfire/PlainDots landed with PR #1202, and the remaining
/// families fan out on the same pattern. Each family's bespoke authors only edit
/// their own registry array — this file just aggregates.
/// </summary>
public static class SubstrateCatalog
{
    public const string PlainId = "plain";

    /// <summary>Iridescent Mesh family — connected-node lattices / caustic light nets.</summary>
    public static readonly SubstrateDescriptor[] Mesh =
    {
        new("mesh.mesh-caustic", SubstrateFamily.Mesh, "Caustic Pool", "caustics",
            new Rgba(1.0, 120 / 255.0, 180 / 255.0), new Rgba(130 / 255.0, 220 / 255.0, 1.0),
            static () => new MeshCausticSubstrate()),
        new("mesh.mesh-patch", SubstrateFamily.Mesh, "Gradient Patch", "patches",
            new Rgba(1.0, 140 / 255.0, 190 / 255.0), new Rgba(1.0, 186 / 255.0, 140 / 255.0),
            static () => new MeshPatchSubstrate()),
        new("mesh.mesh-isoline", SubstrateFamily.Mesh, "Iso Contour", "contours",
            new Rgba(1.0, 150 / 255.0, 200 / 255.0), new Rgba(200 / 255.0, 200 / 255.0, 1.0),
            static () => new MeshIsolineSubstrate()),
        new("mesh.mesh-grain", SubstrateFamily.Mesh, "Living Grain", "grain",
            new Rgba(1.0, 160 / 255.0, 170 / 255.0), new Rgba(1.0, 200 / 255.0, 150 / 255.0),
            static () => new MeshGrainSubstrate()),
    };

    /// <summary>Moiré family — interference-pattern line fields / thin-film sheens.</summary>
    public static readonly SubstrateDescriptor[] Moire =
    {
        new("moire.fringe-bloom", SubstrateFamily.Moire, "Fringe Bloom", "fringes",
            new Rgba(188 / 255.0, 208 / 255.0, 1.0), new Rgba(150 / 255.0, 150 / 255.0, 1.0),
            static () => new FringeBloomSubstrate()),
        new("moire.lattice-facet", SubstrateFamily.Moire, "Lattice Facet", "crystal",
            new Rgba(170 / 255.0, 200 / 255.0, 1.0), new Rgba(200 / 255.0, 180 / 255.0, 1.0),
            static () => new LatticeFacetSubstrate()),
        new("moire.ruling-grating", SubstrateFamily.Moire, "Ruling Grating", "gratings",
            new Rgba(200 / 255.0, 210 / 255.0, 1.0), new Rgba(160 / 255.0, 170 / 255.0, 1.0),
            static () => new RulingGratingSubstrate()),
        new("moire.film-bubble", SubstrateFamily.Moire, "Film Bubble", "bubbles",
            new Rgba(180 / 255.0, 220 / 255.0, 1.0), new Rgba(220 / 255.0, 190 / 255.0, 1.0),
            static () => new FilmBubbleSubstrate()),
    };

    /// <summary>The bespoke descriptors landed by this lane (Mesh + Moiré).</summary>
    public static IEnumerable<SubstrateDescriptor> Bespoke()
    {
        foreach (SubstrateDescriptor d in Mesh) yield return d;
        foreach (SubstrateDescriptor d in Moire) yield return d;
    }

    /// <summary>The bespoke descriptors for one family (plain is host-provided).</summary>
    public static SubstrateDescriptor[] Entries(SubstrateFamily family) => family switch
    {
        SubstrateFamily.Mesh => Mesh,
        SubstrateFamily.Moire => Moire,
        _ => Array.Empty<SubstrateDescriptor>(),
    };

    private static readonly Dictionary<string, SubstrateDescriptor> ById = BuildIndex();

    private static Dictionary<string, SubstrateDescriptor> BuildIndex()
    {
        var map = new Dictionary<string, SubstrateDescriptor>();
        foreach (SubstrateDescriptor d in Bespoke()) map[d.Id] = d;
        return map;
    }

    /// <summary>Look up a descriptor by id; null when not one of this lane's families.</summary>
    public static SubstrateDescriptor? ById_(string id) => ById.TryGetValue(id, out SubstrateDescriptor? d) ? d : null;
}
