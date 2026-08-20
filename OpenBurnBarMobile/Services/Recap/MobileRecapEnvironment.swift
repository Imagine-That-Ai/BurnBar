import Foundation
import SwiftUI
import Observation
import OpenBurnBarCore

/// Owns the recap's stores and composer on iOS, and drives one month's state.
///
/// Same two-tier contract as the Mac: a stored deck paints immediately, the
/// deterministic build replaces it, and an editorial pass may replace it again.
/// The difference is where the rows come from and how much history exists —
/// iOS accumulates months as it sees them rather than backfilling a year from a
/// local database it does not have.
@MainActor
@Observable
final class MobileRecapEnvironment {

    enum Phase: Equatable {
        case idle
        case building
        case ready
        case notEnoughData(RecapWindow)
        case failed(String)
    }

    private(set) var recap: MonthlyRecap?
    private(set) var phase: Phase = .idle
    private(set) var availableMonths: [RecapWindow] = []
    private(set) var selectedMonth: RecapWindow
    private(set) var isPolishing = false

    static let aiToggleKey = "recapPage.llmEditorialEnabled"

    private let historyStore: RecapHistoryStore
    private let recapStore: RecapStore
    private let source: any RecapSource
    private let makeAuthor: @MainActor () -> any RecapVoiceAuthor
    private var buildTask: Task<Void, Never>?

    /// History depth is smaller than the Mac's twelve on purpose: every month
    /// here costs Firestore reads rather than a local scan, so the recap grows
    /// its history as months go by instead of paying for a year up front.
    private let historyDepth: Int

    init(
        source: any RecapSource = MobileRecapSource(),
        makeAuthor: @escaping @MainActor () -> any RecapVoiceAuthor = { RecapVoiceAuthorUnavailable() },
        historyDepth: Int = 3,
        accountID: String? = nil,
        now: Date = Date()
    ) throws {
        let directory = try Self.recapDirectory(accountID: accountID)
        self.source = source
        self.makeAuthor = makeAuthor
        self.historyDepth = historyDepth
        self.historyStore = try RecapHistoryStore(
            fileURL: directory.appendingPathComponent("history.json")
        )
        self.recapStore = try RecapStore(
            fileURL: directory.appendingPathComponent("recaps.json")
        )
        self.selectedMonth = RecapWindow.mostRecentCompleted(asOf: now)
    }

    // MARK: - Months

    func refreshAvailableMonths(now: Date = Date()) async {
        let stored = await recapStore.availableMonths()
        let completed = RecapWindow.mostRecentCompleted(asOf: now)
        availableMonths = Array(Set(stored + [completed, RecapWindow.current(asOf: now)]))
            .sorted(by: >)
    }

    func select(_ window: RecapWindow, now: Date = Date()) {
        guard window != selectedMonth || recap == nil else { return }
        selectedMonth = window
        recap = nil
        load(now: now)
    }

    // MARK: - Loading

    func load(now: Date = Date(), forceRegenerate: Bool = false) {
        buildTask?.cancel()
        phase = .building
        isPolishing = false

        let window = selectedMonth
        let composer = RecapComposer(
            source: source,
            historyStore: historyStore,
            recapStore: recapStore,
            author: makeAuthor(),
            historyDepth: historyDepth
        )

        buildTask = Task { [weak self] in
            guard let self else { return }
            if !forceRegenerate, let cached = await composer.stored(for: window) {
                self.recap = cached
                self.phase = .ready
            }

            for await event in await composer.build(
                window: window, now: now, forceRegenerate: forceRegenerate
            ) {
                guard !Task.isCancelled, self.selectedMonth == window else { return }
                switch event {
                case let .deterministic(deck):
                    self.recap = deck
                    self.phase = .ready
                    self.isPolishing = !deck.sealState.isSealed && self.isEditorialEnabled
                case let .voiced(deck):
                    withAnimation(MobileTheme.Animation.gentle) { self.recap = deck }
                    self.phase = .ready
                    self.isPolishing = false
                case let .notEnoughData(month):
                    if self.recap == nil { self.phase = .notEnoughData(month) }
                    self.isPolishing = false
                case let .failed(message):
                    if self.recap == nil { self.phase = .failed(message) }
                    self.isPolishing = false
                }
            }
            self.isPolishing = false
            await self.refreshAvailableMonths(now: now)
        }
    }

    func cancel() {
        buildTask?.cancel()
        buildTask = nil
        isPolishing = false
    }

    private var isEditorialEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.aiToggleKey)
    }

    // MARK: - Paths

    /// Per-account, because one device signs in as more than one person.
    ///
    /// A shared directory meant the previous account's sealed months — its
    /// projects, its spend, its habits — were served to whoever signed in next.
    /// The id is hashed so the path never carries an address.
    private static func recapDirectory(accountID: String?) throws -> URL {
        let manager = FileManager.default
        var url = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Recap", isDirectory: true)
        url = url.appendingPathComponent(accountScope(accountID), isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func accountScope(_ accountID: String?) -> String {
        guard let accountID, !accountID.isEmpty else { return "local" }
        var hash = UInt64(5381)
        for byte in accountID.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "u%016llx", hash)
    }
}
