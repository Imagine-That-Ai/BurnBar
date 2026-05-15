import AppKit
import Foundation
import SwiftUI
import OpenBurnBarCore

struct BrowserServiceStatusDisplay: Identifiable, Equatable {
    let id: String
    let providerName: String
    let accountLabel: String
    let fiveHour: String
    let sevenDay: String

    var displayText: String {
        "\(providerName): \(accountLabel) · 5h \(fiveHour) · 7d \(sevenDay)"
    }
}

struct SwitcherQuotaWindowDisplay: Identifiable, Equatable {
    let id: String
    let label: String
    let remaining: String
    let resetText: String

    var inlineText: String {
        "\(label) \(remaining) · \(resetText)"
    }
}

func switcherQuotaWindowDisplays(
    snapshot: ProviderQuotaSnapshot?
) -> [SwitcherQuotaWindowDisplay] {
    guard let snapshot else { return [] }

    var displays: [SwitcherQuotaWindowDisplay] = []
    if let hourly = snapshot.hourlyBucket {
        displays.append(switcherQuotaWindowDisplay(bucket: hourly, fallbackLabel: "5h"))
    }
    if let weekly = snapshot.weeklyBucket {
        displays.append(switcherQuotaWindowDisplay(bucket: weekly, fallbackLabel: "7d"))
    }

    if displays.isEmpty, let fallback = snapshot.primaryDisplayableBucket {
        displays.append(switcherQuotaWindowDisplay(bucket: fallback, fallbackLabel: fallback.label))
    }

    return displays
}

func switcherQuotaWindowDisplay(
    bucket: ProviderQuotaBucket,
    fallbackLabel: String
) -> SwitcherQuotaWindowDisplay {
    let label: String
    switch bucket.windowKind {
    case .rollingHours:
        label = "5h"
    case .rollingDays, .weekly:
        label = "7d"
    case .daily:
        label = "24h"
    case .monthly:
        label = "30d"
    case .lifetime, .custom:
        label = fallbackLabel
    }

    let resetText: String
    if let reset = bucket.resetsAtDisplay {
        resetText = "resets \(reset.relative) · \(reset.absolute)"
    } else {
        resetText = "reset unavailable"
    }

    return SwitcherQuotaWindowDisplay(
        id: bucket.key,
        label: label,
        remaining: bucket.remainingText,
        resetText: resetText
    )
}

func browserServiceStatusDisplays(
    for serviceIdentities: [BrowserServiceIdentity],
    quotaLookup: (BrowserServiceProvider) -> ProviderQuotaSnapshot?
) -> [BrowserServiceStatusDisplay] {
    serviceIdentities.map { identity in
        let snapshot = quotaLookup(identity.provider)
        return BrowserServiceStatusDisplay(
            id: identity.provider.rawValue,
            providerName: identity.provider.displayName,
            accountLabel: identity.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? identity.accountLabel!.trimmingCharacters(in: .whitespacesAndNewlines)
                : "signed in",
            fiveHour: snapshot?.hourlyBucket?.remainingText ?? "--",
            sevenDay: snapshot?.weeklyBucket?.remainingText ?? "--"
        )
    }
}

func cliQuotaStatusText(
    for profile: SwitcherProfileRecord,
    quotaLookup: (AgentProvider) -> ProviderQuotaSnapshot?
) -> String? {
    guard let windows = cliQuotaWindowDisplays(for: profile, quotaLookup: quotaLookup),
          !windows.isEmpty else {
        return nil
    }

    return "Quota left · " + windows.map(\.inlineText).joined(separator: " · ")
}

func cliQuotaWindowDisplays(
    for profile: SwitcherProfileRecord,
    quotaLookup: (AgentProvider) -> ProviderQuotaSnapshot?
) -> [SwitcherQuotaWindowDisplay]? {
    guard profile.targetKind == .cli,
          !profile.isDisabled,
          profile.cliMetadata?.accountDescription?.isEmpty == false,
          let cliType = profile.cliType,
          let provider = cliType.agentProvider else {
        return nil
    }

    return switcherQuotaWindowDisplays(snapshot: quotaLookup(provider))
}

func refreshedBrowserProfileRecord(
    profile: SwitcherProfileRecord,
    discoveredChromeProfile: ChromeProfileInfo
) -> SwitcherProfileRecord {
    SwitcherProfileRecord(
        id: profile.id,
        targetKind: .browser,
        browserType: .chrome,
        browserMetadata: SwitcherBrowserProfileMetadata(
            profileIdentifier: profile.browserMetadata?.profileIdentifier ?? discoveredChromeProfile.folderKey,
            displayLabel: discoveredChromeProfile.displayName,
            accountEmail: discoveredChromeProfile.email ?? profile.browserMetadata?.accountEmail,
            providerIdentifier: profile.browserMetadata?.providerIdentifier ?? "google",
            serviceIdentities: discoveredChromeProfile.serviceIdentities,
            isDisabled: profile.browserMetadata?.isDisabled ?? false
        ),
        sortKey: profile.sortKey,
        createdAt: profile.createdAt,
        updatedAt: profile.updatedAt
    )
}

extension BrowserServiceProvider {
    var agentProvider: AgentProvider? {
        switch self {
        case .openAI:
            return .codex
        case .claude:
            return .claudeCode
        }
    }
}

extension SwitcherCLIProfileType {
    var agentProvider: AgentProvider? {
        switch self {
        case .codex:
            return .codex
        case .claude:
            return .claudeCode
        case .opencode:
            return nil
        }
    }
}

extension AccountChangeDestination {
    var browserServiceProvider: BrowserServiceProvider? {
        switch self {
        case .openAI:
            return .openAI
        case .claude:
            return .claude
        case .googleAccount, .appleID:
            return nil
        }
    }
}

enum AccountChangeDestination: Hashable {
    case openAI
    case claude
    case googleAccount
    case appleID

    var label: String {
        switch self {
        case .openAI:
            return "OpenAI / Codex"
        case .claude:
            return "Claude"
        case .googleAccount:
            return "Google Account"
        case .appleID:
            return "Apple ID"
        }
    }

    var subtitle: String {
        switch self {
        case .openAI:
            return "chatgpt.com"
        case .claude:
            return "claude.ai"
        case .googleAccount:
            return "myaccount.google.com"
        case .appleID:
            return "appleid.apple.com"
        }
    }

    var icon: String {
        switch self {
        case .openAI:
            return "bubble.left.fill"
        case .claude:
            return "bubble.right.fill"
        case .googleAccount:
            return "person.badge.key.fill"
        case .appleID:
            return "apple.logo"
        }
    }

    var accentColor: Color {
        switch self {
        case .openAI:
            return Color(hex: "00A67E")
        case .claude:
            return Color(hex: "CC785C")
        case .googleAccount:
            return Color(hex: "4285F4")
        case .appleID:
            return Color(hex: "0071E3")
        }
    }

    var requiresInteractiveAuth: Bool {
        switch self {
        case .googleAccount, .appleID:
            return true
        case .openAI, .claude:
            return false
        }
    }

    var url: URL {
        switch self {
        case .openAI:
            return URL(string: "https://chatgpt.com/")!
        case .claude:
            return URL(string: "https://claude.ai/")!
        case .googleAccount:
            return URL(string: "https://accounts.google.com/AccountChooser?continue=https://myaccount.google.com/")!
        case .appleID:
            return URL(string: "https://appleid.apple.com/sign-in")!
        }
    }
}

enum BrowserAccountChangePlanner {
    static func destinations(
        providerIdentifier: String?,
        serviceIdentities: [BrowserServiceIdentity]
    ) -> [AccountChangeDestination] {
        var ordered: [AccountChangeDestination] = []

        func append(_ destination: AccountChangeDestination) {
            guard !ordered.contains(destination) else { return }
            ordered.append(destination)
        }

        switch providerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "apple":
            append(.appleID)
        case "google":
            append(.googleAccount)
        default:
            break
        }

        for identity in serviceIdentities {
            switch identity.provider {
            case .openAI:
                append(.openAI)
            case .claude:
                append(.claude)
            }
        }

        append(.openAI)
        append(.claude)

        if ordered.isEmpty {
            append(.openAI)
            append(.claude)
        }

        return ordered
    }
}

final class SettingsSwitcherProfileAdapter: SwitcherProfileStoreAdapter, Sendable {
    private let store: SwitcherProfileStore

    init(store: SwitcherProfileStore) {
        self.store = store
    }

    func fetchProfile(id: String) -> SwitcherProfileRecord? {
        try? store.fetchProfile(id: id)
    }

    func fetchAllProfiles() -> [SwitcherProfileRecord] {
        (try? store.fetchAllProfiles()) ?? []
    }

    func fetchActiveProfileID() -> String? {
        try? store.fetchActiveProfileState().activeProfileID
    }

    func setActiveProfileID(_ profileID: String?) {
        try? store.setActiveProfile(profileID)
    }

    func updateProfile(_ profile: SwitcherProfileRecord) {
        try? store.update(profile)
    }
}
