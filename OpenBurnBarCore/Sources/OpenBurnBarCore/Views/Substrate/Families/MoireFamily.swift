import Foundation

/// Moiré family substrate registry. Ported from imaginethat
/// `glyph/stage/styles/moire/`.
enum MoireFamily {
    static let styles: [SubstrateDescriptor] = [
        SubstrateDescriptor(
            id: "moire.fringe-bloom", family: .moire,
            label: "Fringe Bloom", hint: "fringes",
            accent: RGBA(r: 188/255, g: 208/255, b: 1.0), accent2: RGBA(r: 150/255, g: 150/255, b: 1.0),
            make: { FringeBloomSubstrate() }),
        SubstrateDescriptor(
            id: "moire.lattice-facet", family: .moire,
            label: "Lattice Facet", hint: "crystal",
            accent: RGBA(r: 170/255, g: 200/255, b: 1.0), accent2: RGBA(r: 200/255, g: 180/255, b: 1.0),
            make: { LatticeFacetSubstrate() }),
        SubstrateDescriptor(
            id: "moire.ruling-grating", family: .moire,
            label: "Ruling Grating", hint: "gratings",
            accent: RGBA(r: 200/255, g: 210/255, b: 1.0), accent2: RGBA(r: 160/255, g: 170/255, b: 1.0),
            make: { RulingGratingSubstrate() }),
        SubstrateDescriptor(
            id: "moire.film-bubble", family: .moire,
            label: "Film Bubble", hint: "bubbles",
            accent: RGBA(r: 180/255, g: 220/255, b: 1.0), accent2: RGBA(r: 220/255, g: 190/255, b: 1.0),
            make: { FilmBubbleSubstrate() })
    ]
}
