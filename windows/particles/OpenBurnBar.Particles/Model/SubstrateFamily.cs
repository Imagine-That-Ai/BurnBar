namespace OpenBurnBar.Particles.Model;

/// <summary>
/// Port of Swift Core <c>SubstrateFamily</c>
/// (<c>SharedModels/SubstrateFamily.swift</c>). The six substrate families; each
/// owns one shared "Plain · DOTS" descriptor plus four bespoke painters.
/// </summary>
public enum SubstrateFamily
{
    Constellation,
    Flow,
    Aurora,
    Mesh,
    Moire,
    Volumetric,
}

/// <summary>
/// Per-family accent pair — byte-identical port of Swift <c>FamilyAccent</c>
/// (channels from the source <c>FAMILY_ACCENT</c> table, 0–255 → 0–1). Used to
/// seed the <see cref="SubstrateStage"/> fallback and picker-tile accents.
/// </summary>
public static class FamilyAccent
{
    public static Rgba A(SubstrateFamily fam) => fam switch
    {
        SubstrateFamily.Constellation => new Rgba(131 / 255.0, 142 / 255.0, 1.0),
        SubstrateFamily.Flow => new Rgba(86 / 255.0, 198 / 255.0, 224 / 255.0),
        SubstrateFamily.Aurora => new Rgba(170 / 255.0, 130 / 255.0, 1.0),
        SubstrateFamily.Mesh => new Rgba(1.0, 120 / 255.0, 180 / 255.0),
        SubstrateFamily.Moire => new Rgba(188 / 255.0, 208 / 255.0, 1.0),
        SubstrateFamily.Volumetric => new Rgba(120 / 255.0, 180 / 255.0, 1.0),
        _ => new Rgba(131 / 255.0, 142 / 255.0, 1.0),
    };

    public static Rgba A2(SubstrateFamily fam) => fam switch
    {
        SubstrateFamily.Constellation => new Rgba(150 / 255.0, 200 / 255.0, 1.0),
        SubstrateFamily.Flow => new Rgba(150 / 255.0, 236 / 255.0, 232 / 255.0),
        SubstrateFamily.Aurora => new Rgba(236 / 255.0, 150 / 255.0, 232 / 255.0),
        SubstrateFamily.Mesh => new Rgba(1.0, 186 / 255.0, 140 / 255.0),
        SubstrateFamily.Moire => new Rgba(150 / 255.0, 150 / 255.0, 1.0),
        SubstrateFamily.Volumetric => new Rgba(1.0, 200 / 255.0, 150 / 255.0),
        _ => new Rgba(150 / 255.0, 200 / 255.0, 1.0),
    };
}
