using System;
using OpenBurnBar.Particles.Substrates;

namespace OpenBurnBar.Particles.Model;

/// <summary>
/// Static metadata for one substrate style + a factory to build its renderer — C#
/// port of Swift <c>SubstrateDescriptor</c> (<c>Views/Substrate/SubstrateCatalog.swift</c>).
/// </summary>
/// <remarks>
/// The <see cref="Make"/> factory captures nothing, so descriptors are safe to keep in
/// the static catalog. The renderer instance it returns is cached + reused across frames
/// by the host (it may hold per-layout caches — sprites, kNN graphs, stream groupings).
/// </remarks>
public sealed class SubstrateDescriptor
{
    /// <summary>Globally-unique id: <c>"plain"</c> or <c>"&lt;family&gt;.&lt;style&gt;"</c> (persisted).</summary>
    public string Id { get; }

    public SubstrateFamily Family { get; }

    /// <summary>Human label, e.g. "Glass Ribbon".</summary>
    public string Label { get; }

    /// <summary>One texture word, e.g. "ribbon".</summary>
    public string Hint { get; }

    /// <summary>Picker-tile accent A.</summary>
    public Rgba Accent { get; }

    /// <summary>Picker-tile accent A2.</summary>
    public Rgba Accent2 { get; }

    /// <summary>Builds a fresh renderer instance (cached + reused by the host).</summary>
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
