using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates.Flow;

namespace OpenBurnBar.Particles.Substrates.Families;

/// <summary>
/// Flow Field family registry — C# port of Swift <c>Families/FlowFamily.swift</c>.
/// Directional / streaming motion fields: bioluminescent wake, liquid-glass ribbon,
/// calligraphic streamlines, drifting petals. Ids / labels / accents mirror the Swift
/// descriptors byte-for-byte.
/// </summary>
public static class FlowFamily
{
    public static readonly SubstrateDescriptor[] Styles =
    {
        new SubstrateDescriptor(
            id: "flow.plankton-wake", family: SubstrateFamily.Flow,
            label: "Plankton Wake", hint: "bioluminescence",
            accent: new Rgba(86 / 255.0, 198 / 255.0, 224 / 255.0),
            accent2: new Rgba(120 / 255.0, 255 / 255.0, 210 / 255.0),
            make: () => new PlanktonWakeSubstrate()),
        new SubstrateDescriptor(
            id: "flow.glass-ribbon", family: SubstrateFamily.Flow,
            label: "Glass Ribbon", hint: "ribbon",
            accent: new Rgba(120 / 255.0, 210 / 255.0, 235 / 255.0),
            accent2: new Rgba(180 / 255.0, 245 / 255.0, 245 / 255.0),
            make: () => new GlassRibbonSubstrate()),
        new SubstrateDescriptor(
            id: "flow.silk-streamline", family: SubstrateFamily.Flow,
            label: "Silk Streamline", hint: "streamline",
            accent: new Rgba(100 / 255.0, 200 / 255.0, 224 / 255.0),
            accent2: new Rgba(150 / 255.0, 236 / 255.0, 232 / 255.0),
            make: () => new SilkStreamlineSubstrate()),
        new SubstrateDescriptor(
            id: "flow.petal-drift", family: SubstrateFamily.Flow,
            label: "Petal Drift", hint: "petals",
            accent: new Rgba(1.0, 150 / 255.0, 190 / 255.0),
            accent2: new Rgba(1.0, 200 / 255.0, 170 / 255.0),
            make: () => new PetalDriftSubstrate()),
    };
}
