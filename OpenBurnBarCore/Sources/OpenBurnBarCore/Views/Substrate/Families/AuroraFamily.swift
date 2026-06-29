import Foundation

/// Aurora family substrate registry. Ported from imaginethat
/// `glyph/stage/styles/aurora/`.
enum AuroraFamily {
    static let styles: [SubstrateDescriptor] = [
        SubstrateDescriptor(
            id: "aurora.wisp", family: .aurora,
            label: "Wisp Plasma", hint: "will-o-wisp",
            accent: RGBA(r: 170/255, g: 130/255, b: 1.0), accent2: RGBA(r: 236/255, g: 150/255, b: 232/255),
            make: { WispSubstrate() }),
        SubstrateDescriptor(
            id: "aurora.ice-prism", family: .aurora,
            label: "Polar Ice Prism", hint: "glacier-facets",
            accent: RGBA(r: 150/255, g: 200/255, b: 1.0), accent2: RGBA(r: 200/255, g: 230/255, b: 1.0),
            make: { IcePrismSubstrate() }),
        SubstrateDescriptor(
            id: "aurora.filament", family: .aurora,
            label: "Aurora Filament", hint: "filament",
            accent: RGBA(r: 150/255, g: 1.0, b: 200/255), accent2: RGBA(r: 170/255, g: 150/255, b: 1.0),
            make: { AuroraFilamentSubstrate() }),
        SubstrateDescriptor(
            id: "aurora.drift-motes", family: .aurora,
            label: "Drift Motes", hint: "spores",
            accent: RGBA(r: 200/255, g: 180/255, b: 1.0), accent2: RGBA(r: 1.0, g: 220/255, b: 240/255),
            make: { DriftMotesSubstrate() })
    ]
}
