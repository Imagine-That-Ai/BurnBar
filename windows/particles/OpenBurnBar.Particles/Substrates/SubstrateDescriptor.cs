using System;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// Static metadata for one substrate style + a factory to build its renderer — C#
/// port of Swift <c>SubstrateDescriptor</c> (<c>Views/Substrate/SubstrateCatalog.swift</c>).
/// The <see cref="Make"/> factory captures nothing, so descriptors are safe to hold in
/// the static <see cref="Catalog.SubstrateCatalog"/> lists.
/// </summary>
public sealed class SubstrateDescriptor
{
    /// <summary>Globally-unique id: <c>"plain"</c> or <c>"&lt;family&gt;.&lt;style&gt;"</c> (persisted).</summary>
    public string Id { get; }
    public SubstrateFamily Family { get; }
    public string Label { get; }   // "Stellar Plasma"
    public string Hint { get; }    // ONE texture word: "twinkle"
    public Rgba Accent { get; }     // picker tile accent a
    public Rgba Accent2 { get; }    // picker tile accent a2

    /// <summary>Builds a fresh renderer instance (cached &amp; reused by the host).</summary>
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
