import Foundation

/// Volumetric family substrate registry. Ported from imaginethat
/// `glyph/stage/styles/volumetric/`.
enum VolumetricFamily {
    static let styles: [SubstrateDescriptor] = [
        SubstrateDescriptor(
            id: "volumetric.sunshaft", family: .volumetric,
            label: "Crepuscular Shafts", hint: "godrays",
            accent: RGBA(r: 120/255, g: 180/255, b: 1.0), accent2: RGBA(r: 1.0, g: 200/255, b: 150/255),
            make: { SunshaftSubstrate() }),
        SubstrateDescriptor(
            id: "volumetric.smoked-glass", family: .volumetric,
            label: "Smoked Glass Slab", hint: "glass",
            accent: RGBA(r: 150/255, g: 170/255, b: 200/255), accent2: RGBA(r: 200/255, g: 210/255, b: 230/255),
            make: { SmokedGlassSubstrate() }),
        SubstrateDescriptor(
            id: "volumetric.silk-filament", family: .volumetric,
            label: "Silk Filament", hint: "filament",
            accent: RGBA(r: 140/255, g: 190/255, b: 1.0), accent2: RGBA(r: 1.0, g: 215/255, b: 170/255),
            make: { SilkFilamentSubstrate() }),
        SubstrateDescriptor(
            id: "volumetric.dust-motes", family: .volumetric,
            label: "Dust Motes", hint: "motes",
            accent: RGBA(r: 200/255, g: 200/255, b: 220/255), accent2: RGBA(r: 1.0, g: 210/255, b: 180/255),
            make: { DustMotesSubstrate() }),
    ]
}
