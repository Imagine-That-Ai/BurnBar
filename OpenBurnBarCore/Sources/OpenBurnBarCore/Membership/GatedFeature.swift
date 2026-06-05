import Foundation

// MARK: - Feature Gating & Evocative Upsell — shared foundation
//
// Canonical spec: docs/FEATURE_GATING_SPEC.md
//
// This file is the single shared data source for the BurnBar feature-gating
// experience on Apple platforms. iOS/iPadOS and macOS both consume this exact
// catalog so the unlock copy is identical everywhere. (Android carries a
// parallel Kotlin catalog — keep both in sync with §3 of the spec.)
//
// Pure Foundation only — NO SwiftUI / UIKit / AppKit — so it compiles in the
// SPM package on every platform. UI layers map `iconSystemName` to an SF Symbol
// and `crestAssetName` to the per-tier holographic crest asset.
//
// Copy below is VERBATIM from spec §3 and is honesty-checked:
//   • "Agent Control" — never "Computer Use" in user copy.
//   • The cloak is NOT described as "inversion-proof" / "fully unlinkable".
//   • Chat / agent memory is NEVER called "end-to-end encrypted" — agent
//     memory is "sealed on-device; the server searches over it without reading
//     your content, though some patterns stay visible".
//     The only feature that legitimately claims E2E is Floo (paired devices).

// MARK: - CloudTier

/// The unified subscription-tier ladder. `Ultra ⊇ Pro ⊇ Cloud`: a user entitled
/// at a higher tier passes every lower-tier gate. Each platform derives this
/// from its existing entitlement predicates (see spec §4.2).
public enum CloudTier: Int, Codable, Sendable, Hashable, CaseIterable {
    case none = 0
    case cloud = 1
    case pro = 2
    case ultra = 3

    /// `true` when this tier is at least `required` — i.e. it satisfies the
    /// gate. Higher tiers subsume lower ones.
    public func satisfies(_ required: CloudTier) -> Bool {
        rawValue >= required.rawValue
    }

    /// Marketing display name for the tier ("Cloud", "Cloud Pro", "Cloud
    /// Ultra"). `none` has no marketing surface, so it reads as an empty
    /// string — callers should never present `none` in upsell UI.
    public var displayName: String {
        switch self {
        case .none:  return ""
        case .cloud: return "Cloud"
        case .pro:   return "Cloud Pro"
        case .ultra: return "Cloud Ultra"
        }
    }

    /// The per-tier holographic crest asset name (spec §2). Mapped by tier:
    /// cloud→`CloudTierCrest`, pro→`CloudTierCrestPro`, ultra→`CloudTierCrestUltra`.
    /// `none` falls back to the base Cloud crest so UI never renders a missing
    /// asset.
    public var crestAssetName: String {
        switch self {
        case .none, .cloud: return "CloudTierCrest"
        case .pro:          return "CloudTierCrestPro"
        case .ultra:        return "CloudTierCrestUltra"
        }
    }
}

// MARK: - GatedFeatureID

/// Stable identifiers for every gated feature. `rawValue` is a stable string
/// key (used for analytics + cross-platform parity with the Kotlin catalog).
public enum GatedFeatureID: String, CaseIterable, Sendable, Codable, Hashable {
    case cloudBackup
    case crossDeviceResume
    case cloudSearch
    case agentControl
    case floo
    case hostedMCP
    case dataVault
    case tenXMemory
}

// MARK: - GatedFeature

/// One gated feature's full presentation data, consumed by both the resting
/// `TierLockBadge` and the `LockedFeatureVeil` / `FeatureUnlockSheet` unlock
/// experiences. All copy is verbatim from spec §3.
public struct GatedFeature: Sendable, Identifiable, Hashable, Codable {
    /// Stable feature id.
    public let id: GatedFeatureID
    /// The marketing-facing feature name (e.g. "Agent Control", "Floo").
    public let publicName: String
    /// The minimum tier that unlocks this feature.
    public let requiredTier: CloudTier
    /// The single evocative desire line shown beneath the hero crest.
    public let oneLineBenefit: String
    /// The 3–4 "what you'll unlock" benefit bullets.
    public let benefitBullets: [String]
    /// SF Symbol name for the feature's glyph.
    public let iconSystemName: String
    /// The holographic crest asset for the required tier (derived from
    /// `requiredTier.crestAssetName`).
    public let crestAssetName: String

    public init(
        id: GatedFeatureID,
        publicName: String,
        requiredTier: CloudTier,
        oneLineBenefit: String,
        benefitBullets: [String],
        iconSystemName: String,
        crestAssetName: String
    ) {
        self.id = id
        self.publicName = publicName
        self.requiredTier = requiredTier
        self.oneLineBenefit = oneLineBenefit
        self.benefitBullets = benefitBullets
        self.iconSystemName = iconSystemName
        self.crestAssetName = crestAssetName
    }
}

// MARK: - Catalog

public extension GatedFeature {
    /// The full catalog keyed by feature id. Copy verbatim from spec §3; the
    /// crest asset for each entry is derived from its required tier so the
    /// mapping can never drift from §2.
    static let allGatedFeatures: [GatedFeatureID: GatedFeature] = {
        var catalog: [GatedFeatureID: GatedFeature] = [:]
        for feature in orderedGatedFeatures {
            catalog[feature.id] = feature
        }
        return catalog
    }()

    /// The catalog in spec §3 order (Cloud features, then Pro, then Ultra).
    /// Useful for any surface that lists features top-to-bottom.
    static let orderedGatedFeatures: [GatedFeature] = [
        // MARK: cloudBackup — BurnBar Cloud (encrypted history + backup) — cloud
        GatedFeature(
            id: .cloudBackup,
            publicName: "BurnBar Cloud",
            requiredTier: .cloud,
            oneLineBenefit: "Every agent conversation, backed up and safe — so a wiped Mac never means a lost thread.",
            benefitBullets: [
                "Your whole session history rides along, encrypted, ready to pick back up the moment you sign in on any device",
                "Hosted quota refresh keeps your five-hour and weekly windows current even when your Mac is asleep",
                "Reinstall, switch machines, or hand off to a new laptop — your runs are already there waiting",
                "One verified subscription lights up everything in Cloud across iPhone, iPad, and Mac"
            ],
            iconSystemName: "icloud.fill",
            crestAssetName: CloudTier.cloud.crestAssetName
        ),

        // MARK: crossDeviceResume — Cross-device resume — cloud
        GatedFeature(
            id: .crossDeviceResume,
            publicName: "Cross-device resume",
            requiredTier: .cloud,
            oneLineBenefit: "Start on your Mac, keep going on your phone — the conversation never drops the thread.",
            benefitBullets: [
                "Walk away from your desk mid-run and pick the exact same conversation back up on your iPhone or iPad",
                "No copy-paste, no re-explaining context — the agent remembers where you both left off",
                "Your iPhone, iPad, and Mac stay in lockstep, the same backed-up history on every screen"
            ],
            iconSystemName: "arrow.triangle.2.circlepath",
            crestAssetName: CloudTier.cloud.crestAssetName
        ),

        // MARK: cloudSearch — Cloud search — cloud
        GatedFeature(
            id: .cloudSearch,
            publicName: "Cloud search",
            requiredTier: .cloud,
            oneLineBenefit: "Find that one answer from three weeks ago — searchable across every device, in seconds.",
            benefitBullets: [
                "Search your entire encrypted session history from any signed-in device, not just the Mac it happened on",
                "That fix, that command, that explanation — surface it instantly instead of scrolling forever",
                "Your past work becomes a searchable library, everywhere you are"
            ],
            iconSystemName: "magnifyingglass",
            crestAssetName: CloudTier.cloud.crestAssetName
        ),

        // MARK: agentControl — Agent Control — cloud_pro
        GatedFeature(
            id: .agentControl,
            publicName: "Agent Control",
            requiredTier: .pro,
            oneLineBenefit: "Hand off the busywork and watch an agent do it — every click in plain sight, every step under your grant.",
            benefitBullets: [
                "Let an agent drive a real browser to fill the form, pull the data, click through the flow while your hands stay free",
                "Watch every move live on your Mac or mirrored to your phone — nothing ever happens out of sight",
                "Approve each step, or set the lines once and let it move freely inside them; mark off-limits windows it can never touch",
                "Stop it instantly with a shortcut or a gesture, and read back a tamper-proof record of everything it did"
            ],
            iconSystemName: "cursorarrow.rays",
            crestAssetName: CloudTier.pro.crestAssetName
        ),

        // MARK: floo — Floo (phone ↔ Mac) — cloud_pro
        GatedFeature(
            id: .floo,
            publicName: "Floo",
            requiredTier: .pro,
            oneLineBenefit: "Your Mac, in your pocket — see it, reach in, and run it from your phone, end to end private.",
            benefitBullets: [
                "Open a live view of your whole desktop, or just one window, and watch a long agent run from the couch",
                "Reach in and take over: tap, scroll, and type — touch a field and your keyboard rises and zooms right to it",
                "Send a file, screenshot, or photo either direction in a tap; share one clipboard across both devices",
                "Call your Mac, or unlock it with Face ID — your password sealed end to end, never in a log or a server"
            ],
            iconSystemName: "iphone.gen3.radiowaves.left.and.right",
            crestAssetName: CloudTier.pro.crestAssetName
        ),

        // MARK: hostedMCP — Hosted Remote MCP — cloud_pro
        GatedFeature(
            id: .hostedMCP,
            publicName: "Hosted Remote MCP",
            requiredTier: .pro,
            oneLineBenefit: "Give any agent, anywhere, a secure line into your sealed memory and tools — no Mac required.",
            benefitBullets: [
                "Your hosted endpoint lets a remote agent recall your private knowledge without anything running on your Mac",
                "The server runs the search and routes the tools, but never reads your content",
                "Always-on access from your phone, a cloud agent, or another tool — isolated to your account alone"
            ],
            iconSystemName: "server.rack",
            crestAssetName: CloudTier.pro.crestAssetName
        ),

        // MARK: dataVault — Data Vault / agent memory — cloud_pro
        GatedFeature(
            id: .dataVault,
            publicName: "Data Vault",
            requiredTier: .pro,
            oneLineBenefit: "A private memory your agents can recall — your repo docs, notes, and chats, sealed on your device.",
            benefitBullets: [
                "Your agents quietly recall the repo docs, notes, and chat-derived memories that matter, mid-task",
                "Every chunk of text is sealed on your device before it leaves — the server searches over the sealed structures, though some patterns stay visible",
                "Nearest-neighbor recall finds the right memory by meaning, not by exposing a single word of your content",
                "Sources, chunks, and storage you control, with one tap to delete any source or purge it all"
            ],
            iconSystemName: "brain.head.profile",
            crestAssetName: CloudTier.pro.crestAssetName
        ),

        // MARK: tenXMemory — 10× agent memory — cloud_ultra
        GatedFeature(
            id: .tenXMemory,
            publicName: "10× agent memory",
            requiredTier: .ultra,
            oneLineBenefit: "Give your agents a whole second brain — 10× the private memory they can recall while they work.",
            benefitBullets: [
                "Jump from 3 sources to 15, from 5,000 memory chunks to 50,000, from 25 MB to 250 MB of recallable knowledge",
                "Feed in far more repo docs, notes, and chat memories so your agents stay deeply in context across big projects",
                "Same on-device seal and cloaked vectors — the server searches over them without reading your content, though some patterns stay visible",
                "Everything in Cloud Pro stays included: Floo, Agent Control, and the same hosted action and relay allowance"
            ],
            iconSystemName: "sparkles",
            crestAssetName: CloudTier.ultra.crestAssetName
        )
    ]

    /// Look up the gated feature for an id. Total over `GatedFeatureID` — every
    /// case is populated in the catalog, so this never returns `nil`.
    static func gatedFeature(_ id: GatedFeatureID) -> GatedFeature {
        // Force-unwrap is safe: a compile-time check below proves the catalog
        // covers every id, so a missing entry is a programmer error we want to
        // surface loudly rather than silently degrade.
        guard let feature = allGatedFeatures[id] else {
            preconditionFailure("GatedFeature catalog is missing an entry for \(id.rawValue)")
        }
        return feature
    }
}
