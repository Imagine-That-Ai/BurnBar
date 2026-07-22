import SwiftUI
import OpenBurnBarKernel

// MARK: - Substrate descriptor + catalog

/// Static metadata for one substrate style + a factory to build its renderer.
public struct SubstrateDescriptor: Identifiable, Sendable {
    /// Globally-unique id: `"plain"` or `"<family>.<style>"` (persisted).
    public let id: String
    public let family: SubstrateFamily
    public let label: String          // "Stellar Plasma"
    public let hint: String           // ONE texture word: "twinkle"
    public let accent: RGBA           // picker tile accent a
    public let accent2: RGBA          // picker tile accent a2
    /// Builds a fresh renderer instance (cached & reused by the simulation).
    /// `@Sendable` (the factories capture nothing) so descriptors are `Sendable`
    /// and the static catalog lists are concurrency-safe.
    public let make: @MainActor @Sendable () -> SwarmSubstrate

    public init(id: String, family: SubstrateFamily, label: String, hint: String,
                accent: RGBA, accent2: RGBA, make: @escaping @MainActor @Sendable () -> SwarmSubstrate) {
        self.id = id; self.family = family; self.label = label; self.hint = hint
        self.accent = accent; self.accent2 = accent2; self.make = make
    }
}

/// The single substrate registry. The bespoke authors never touch this file —
/// each only edits their own family registry (`Families/<Family>Family.swift`).
/// This aggregates the six family arrays + the one shared plain, giving the
/// 30-entry catalog exactly seven edit points.
public enum SubstrateCatalog {
    public static let plainID = "plain"

    /// All 30 = 6 plain descriptors (one shared renderer) + 24 bespoke.
    public static let substrateList: [SubstrateDescriptor] =
        plainDescriptors
        + ConstellationFamily.styles
        + FlowFamily.styles
        + AuroraFamily.styles
        + MeshFamily.styles
        + MoireFamily.styles
        + VolumetricFamily.styles

    /// Lookup by id. All six plain descriptors share id `"plain"`; the first wins
    /// (they're the same family-agnostic renderer, so it doesn't matter).
    public static let byID: [String: SubstrateDescriptor] =
        Dictionary(substrateList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// The styles offered for the active kernel — its family's five, plain first.
    public static func styles(forKernel kernelID: String) -> [SubstrateDescriptor] {
        let fam = SubstrateFamily.forKernel(kernelID)
        return [plain(for: fam)] + bespoke(for: fam)
    }

    public static func entries(in family: SubstrateFamily) -> [SubstrateDescriptor] {
        [plain(for: family)] + bespoke(for: family)
    }

    /// Resolve the descriptor to actually render. The selected id only "lights up"
    /// on the kernel theme whose family owns it; otherwise the active family's
    /// plain is used — exactly the web behavior where switching worlds shows that
    /// world's suite.
    public static func resolved(forKernel kernelID: String, selectedID: String) -> SubstrateDescriptor {
        let fam = SubstrateFamily.forKernel(kernelID)
        if let d = byID[selectedID], d.family == fam { return d }
        if selectedID == plainID { return plain(for: fam) }
        return plain(for: fam)
    }

    /// Convenience: the resolved descriptor for the live `UserDefaults` selection.
    public static func resolvedCurrent(forKernel kernelID: String) -> SubstrateDescriptor {
        guard SwarmSubstratePreferences.isEnabled else { return plain(for: .forKernel(kernelID)) }
        return resolved(forKernel: kernelID, selectedID: SwarmSubstratePreferences.currentID)
    }

    // MARK: Internals

    /// One "Plain · DOTS" descriptor per family (all reuse `PlainDotsSubstrate`).
    private static let plainDescriptors: [SubstrateDescriptor] =
        SubstrateFamily.allCases.map { fam in
            SubstrateDescriptor(
                id: plainID, family: fam, label: "Plain", hint: "dots",
                accent: FamilyAccent.a(fam), accent2: FamilyAccent.a2(fam),
                make: { PlainDotsSubstrate() })
        }

    public static func plain(for fam: SubstrateFamily) -> SubstrateDescriptor {
        plainDescriptors.first { $0.family == fam }!
    }

    public static func bespoke(for fam: SubstrateFamily) -> [SubstrateDescriptor] {
        substrateList.filter { $0.family == fam && $0.id != plainID }
    }
}
