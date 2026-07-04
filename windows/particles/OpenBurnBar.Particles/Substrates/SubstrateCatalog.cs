using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates.Families;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// The single Windows substrate registry — C# port of Swift
/// <c>Views/Substrate/SubstrateCatalog.swift</c>. It aggregates the six per-family
/// "Plain · DOTS" descriptors (one shared <see cref="PlainDotsSubstrate"/> renderer)
/// with each family's bespoke painters, giving the picker + host one lookup surface.
/// </summary>
/// <remarks>
/// The bespoke authors never edit this file — each only edits their own
/// <c>Families/&lt;Family&gt;Family.cs</c>. The Wave-4 integration completes the
/// <b>Flow</b>, <b>Aurora</b> (PR #1212), <b>Mesh</b>, <b>Moiré</b> (PR #1214),
/// <b>Volumetric</b> and the remaining <b>Constellation</b> (PR #1213) families, and
/// carries the already-landed Constellation <c>Starfire</c> (PR #1202). Any family
/// without a ported painter falls back to just its shared plain descriptor (never a
/// dangling reference to an unported class).
/// </remarks>
public static class SubstrateCatalog
{
    public const string PlainId = "plain";

    /// <summary>Bespoke styles per family (plain is added separately, first).</summary>
    private static readonly Dictionary<SubstrateFamily, SubstrateDescriptor[]> Bespoke = new()
    {
        [SubstrateFamily.Constellation] = ConstellationFamily.Styles,
        [SubstrateFamily.Flow] = FlowFamily.Styles,
        [SubstrateFamily.Aurora] = AuroraFamily.Styles,
        [SubstrateFamily.Mesh] = MeshFamily.Styles,
        [SubstrateFamily.Moire] = MoireFamily.Styles,
        [SubstrateFamily.Volumetric] = VolumetricFamily.Styles,
    };

    private static readonly SubstrateFamily[] Families =
    {
        SubstrateFamily.Constellation, SubstrateFamily.Flow, SubstrateFamily.Aurora,
        SubstrateFamily.Mesh, SubstrateFamily.Moire, SubstrateFamily.Volumetric,
    };

    /// <summary>One "Plain · DOTS" descriptor per family (all reuse the shared renderer).</summary>
    private static readonly SubstrateDescriptor[] PlainDescriptors =
        Families.Select(fam => new SubstrateDescriptor(
            id: PlainId, family: fam, label: "Plain", hint: "dots",
            accent: FamilyAccent.A(fam), accent2: FamilyAccent.A2(fam),
            make: () => new PlainDotsSubstrate())).ToArray();

    /// <summary>All registered descriptors: the six plain + every ported bespoke.</summary>
    public static readonly SubstrateDescriptor[] SubstrateList =
        PlainDescriptors
            .Concat(Families.SelectMany(f => Bespoke[f]))
            .ToArray();

    /// <summary>Lookup by id (first plain wins, as in the Swift catalog).</summary>
    public static readonly IReadOnlyDictionary<string, SubstrateDescriptor> ById =
        SubstrateList
            .GroupBy(d => d.Id)
            .ToDictionary(g => g.Key, g => g.First());

    /// <summary>The shared plain descriptor for a family.</summary>
    public static SubstrateDescriptor Plain(SubstrateFamily fam) =>
        PlainDescriptors.First(d => d.Family == fam);

    /// <summary>The bespoke descriptors for a family (may be empty for not-yet-ported families).</summary>
    public static SubstrateDescriptor[] BespokeFor(SubstrateFamily fam) => Bespoke[fam];

    /// <summary>The styles offered for a family — its plain first, then its bespoke.</summary>
    public static SubstrateDescriptor[] Entries(SubstrateFamily fam)
    {
        SubstrateDescriptor[] b = Bespoke[fam];
        var outp = new SubstrateDescriptor[b.Length + 1];
        outp[0] = Plain(fam);
        Array.Copy(b, 0, outp, 1, b.Length);
        return outp;
    }
}
