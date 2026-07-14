import Foundation
import OpenBurnBarKernel

/// Flow Field family substrate registry. Ported from imaginethat
/// `glyph/stage/styles/flow/`.
enum FlowFamily {
    static let styles: [SubstrateDescriptor] = [
        SubstrateDescriptor(
            id: "flow.plankton-wake", family: .flow,
            label: "Plankton Wake", hint: "bioluminescence",
            accent: RGBA(r: 86/255, g: 198/255, b: 224/255), accent2: RGBA(r: 120/255, g: 255/255, b: 210/255),
            make: { PlanktonWakeSubstrate() }),
        SubstrateDescriptor(
            id: "flow.glass-ribbon", family: .flow,
            label: "Glass Ribbon", hint: "ribbon",
            accent: RGBA(r: 120/255, g: 210/255, b: 235/255), accent2: RGBA(r: 180/255, g: 245/255, b: 245/255),
            make: { GlassRibbonSubstrate() }),
        SubstrateDescriptor(
            id: "flow.silk-streamline", family: .flow,
            label: "Silk Streamline", hint: "streamline",
            accent: RGBA(r: 100/255, g: 200/255, b: 224/255), accent2: RGBA(r: 150/255, g: 236/255, b: 232/255),
            make: { SilkStreamlineSubstrate() }),
        SubstrateDescriptor(
            id: "flow.petal-drift", family: .flow,
            label: "Petal Drift", hint: "petals",
            accent: RGBA(r: 1.0, g: 150/255, b: 190/255), accent2: RGBA(r: 1.0, g: 200/255, b: 170/255),
            make: { PetalDriftSubstrate() })
    ]
}
