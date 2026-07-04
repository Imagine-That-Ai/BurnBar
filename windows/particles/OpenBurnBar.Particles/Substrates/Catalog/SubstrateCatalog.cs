using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Substrates.Catalog;

/// <summary>
/// The single substrate registry — C# port of Swift
/// <c>Views/Substrate/SubstrateCatalog.swift</c>. Aggregates one shared "Plain · DOTS"
/// descriptor per family plus each family's bespoke painters. Family registries are the
/// only per-family edit points (matching the Swift design), so each ported family
/// (Constellation, Volumetric here; Flow / Aurora / Mesh / Moire as those lanes land)
/// appends its own <c>&lt;Family&gt;Family.Styles</c> array below — this file is the one
/// documented merge point.
/// </summary>
public static class SubstrateCatalog
{
    public const string PlainId = "plain";

    /// <summary>The families whose bespoke painters are registered in the C# port so far.</summary>
    public static readonly IReadOnlyList<SubstrateFamily> RegisteredFamilies = new[]
    {
        SubstrateFamily.Constellation,
        SubstrateFamily.Volumetric,
    };

    /// <summary>Plain descriptors (one per registered family; all reuse <see cref="PlainDotsSubstrate"/>).</summary>
    private static readonly IReadOnlyList<SubstrateDescriptor> PlainDescriptors =
        RegisteredFamilies.Select(fam => new SubstrateDescriptor(
            PlainId, fam, "Plain", "dots",
            FamilyAccent.A(fam), FamilyAccent.A2(fam),
            static () => new PlainDotsSubstrate())).ToArray();

    /// <summary>Plain + every bespoke descriptor across the registered families.</summary>
    public static readonly IReadOnlyList<SubstrateDescriptor> SubstrateList =
        PlainDescriptors
            .Concat(ConstellationFamily.Styles)
            .Concat(VolumetricFamily.Styles)
            .ToArray();

    /// <summary>Lookup by id. The plain descriptors share id <c>"plain"</c>; the first wins.</summary>
    public static readonly IReadOnlyDictionary<string, SubstrateDescriptor> ById =
        SubstrateList
            .GroupBy(d => d.Id)
            .ToDictionary(g => g.Key, g => g.First());

    /// <summary>The bespoke descriptors for one family (no plain).</summary>
    public static IEnumerable<SubstrateDescriptor> Bespoke(SubstrateFamily fam) =>
        SubstrateList.Where(d => d.Family == fam && d.Id != PlainId);

    /// <summary>The shared plain descriptor for one family.</summary>
    public static SubstrateDescriptor Plain(SubstrateFamily fam) =>
        PlainDescriptors.First(d => d.Family == fam);

    /// <summary>A family's full offering — its plain first, then its bespoke painters.</summary>
    public static IEnumerable<SubstrateDescriptor> Entries(SubstrateFamily fam) =>
        new[] { Plain(fam) }.Concat(Bespoke(fam));
}
