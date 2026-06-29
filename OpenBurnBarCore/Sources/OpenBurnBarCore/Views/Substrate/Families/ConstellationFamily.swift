import Foundation

/// Constellation family substrate registry — the only catalog edit point for the
/// four Constellation bespoke authors. Ported from imaginethat
/// `glyph/stage/styles/constellation/`.
enum ConstellationFamily {
    static let styles: [SubstrateDescriptor] = [
        SubstrateDescriptor(
            id: "constellation.starfire", family: .constellation,
            label: "Stellar Plasma", hint: "twinkle",
            accent: RGBA(r: 131/255, g: 142/255, b: 1.0), accent2: RGBA(r: 150/255, g: 200/255, b: 1.0),
            make: { StarfireSubstrate() }),
        SubstrateDescriptor(
            id: "constellation.starsapphire", family: .constellation,
            label: "Cut Star Sapphire", hint: "facets",
            accent: RGBA(r: 120/255, g: 170/255, b: 1.0), accent2: RGBA(r: 180/255, g: 220/255, b: 1.0),
            make: { StarSapphireSubstrate() }),
        SubstrateDescriptor(
            id: "constellation.stellarium", family: .constellation,
            label: "Drawn Constellation", hint: "lines",
            accent: RGBA(r: 150/255, g: 170/255, b: 1.0), accent2: RGBA(r: 200/255, g: 215/255, b: 1.0),
            make: { StellariumSubstrate() }),
        SubstrateDescriptor(
            id: "constellation.rimefrost", family: .constellation,
            label: "Dendritic Frost", hint: "frost",
            accent: RGBA(r: 190/255, g: 215/255, b: 1.0), accent2: RGBA(r: 225/255, g: 240/255, b: 1.0),
            make: { RimefrostSubstrate() }),
    ]
}
