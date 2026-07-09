import Foundation
import OpenBurnBarCore
import OpenBurnBarFirestoreModels

@MainActor
final class CommunityViewModel: ObservableObject {
    struct TierBoard: Identifiable {
        let tier: FirestoreGeographyTier
        let geoLabel: String
        let geoKey: String
        var board: FirestoreCommunityLeaderboardDoc?

        var id: String { "\(tier.rawValue)-\(geoKey)" }
    }

    @Published var selectedWindow: CommunityLeaderboardWindow = .sevenDays
    @Published var tierBoards: [TierBoard] = []
    @Published var isLoadingBoards = false
    @Published var purposeBreakdown: [(category: ModelPurposeCategory, share: Double)] = []

    let consentStore: CommunityConsentStore
    let service: CommunityService

    init(consentStore: CommunityConsentStore, service: CommunityService) {
        self.consentStore = consentStore
        self.service = service
    }

    var pinnedAnonId: String? { service.profile?.anonId }

    func refreshAll(usages: [TokenUsage]) async {
        await service.refreshOwnerDocs()
        await reloadBoards()
        recomputePurposeBreakdown(usages: usages)
    }

    func reloadBoards() async {
        isLoadingBoards = true
        defer { isLoadingBoards = false }

        let profile = service.profile
        var specs: [(FirestoreGeographyTier, String, String)] = [
            (.world, "World", "world")
        ]
        if let cc = profile?.countryCode, !cc.isEmpty {
            specs.append((.country, cc.uppercased(), cc))
        }
        if let rk = profile?.regionKey, !rk.isEmpty {
            specs.append((.region, rk, rk))
        }
        if let ck = profile?.cityKey, !ck.isEmpty {
            specs.append((.city, ck, ck))
        }

        specs.reverse()

        var loaded: [TierBoard] = []
        for spec in specs {
            var entry = TierBoard(tier: spec.0, geoLabel: spec.1, geoKey: spec.2, board: nil)
            do {
                entry.board = try await service.fetchLeaderboard(
                    window: selectedWindow,
                    tier: spec.0,
                    geoKey: spec.2
                )
            } catch {
                entry.board = nil
            }
            loaded.append(entry)
        }
        tierBoards = loaded
    }

    func recomputePurposeBreakdown(usages: [TokenUsage]) {
        var counts: [ModelPurposeCategory: Int] = [:]
        for usage in usages.prefix(80) {
            let keywords = usage.projectName
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            let signals = ClassifierSignals(
                model: usage.model,
                appSurface: "dashboard",
                keywords: keywords
            )
            let result = ModelPurposeClassifier.classifyPurpose(signals)
            counts[result.category, default: 0] += 1
        }
        let total = max(counts.values.reduce(0, +), 1)
        purposeBreakdown = ModelPurposeCategory.allCases.compactMap { cat in
            guard let c = counts[cat], c > 0 else { return nil }
            return (cat, Double(c) / Double(total))
        }.sorted { $0.share > $1.share }
    }

    func percentileBands(from boards: [TierBoard]) -> FirestorePercentileBands? {
        for entry in boards {
            guard let board = entry.board, !board.belowThreshold else { continue }
            return board.percentiles
        }
        return nil
    }

    func cohortTokens(from boards: [TierBoard]) -> [Int] {
        guard let world = boards.first(where: { $0.tier == .world })?.board,
              !world.belowThreshold else { return [] }
        return world.entries.map { Int($0.totalTokens) }
    }
}
