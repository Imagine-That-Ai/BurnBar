import Foundation
import SwiftUI
import Observation
import OpenBurnBarKernel
import OpenBurnBarRecap

/// Owns the recap's stores and composer for the macOS app, and drives one
/// month's state for the page.
///
/// Two-tier by construction: `recap` is populated from the store the moment a
/// month is selected, then replaced by the deterministic build, then again by
/// the edited one. The view never waits on a model.
@MainActor
@Observable
final class MacRecapEnvironment {

    // MARK: State

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
    /// True while the editorial pass is still running behind a shown deck.
    private(set) var isPolishing = false

    /// Mirrors the Charts page's opt-in switch, including its storage-key shape.
    static let aiToggleKey = "recapPage.llmEditorialEnabled"

    // MARK: Dependencies

    private let dataStore: DataStore
    private let historyStore: RecapHistoryStore
    private let recapStore: RecapStore
    private let bridge: CLIBridge
    private let enabledBackends: @MainActor () -> [ChatBackendID]
    private var buildTask: Task<Void, Never>?

    init(
        dataStore: DataStore,
        bridge: CLIBridge,
        enabledBackends: @escaping @MainActor () -> [ChatBackendID],
        now: Date = Date()
    ) throws {
        let directory = try Self.recapDirectory()
        self.dataStore = dataStore
        self.bridge = bridge
        self.enabledBackends = enabledBackends
        self.historyStore = try RecapHistoryStore(
            fileURL: directory.appendingPathComponent("history.json")
        )
        self.recapStore = try RecapStore(
            fileURL: directory.appendingPathComponent("recaps.json")
        )
        // Opens on the most recent *completed* month. The month in progress is
        // reachable, but a recap of a month that is still happening is a
        // preview, not the thing people come here for.
        self.selectedMonth = RecapWindow.mostRecentCompleted(asOf: now)
    }

    // MARK: - Months

    /// Months worth offering in the picker: everything stored, plus the last
    /// completed month and the one in progress.
    func refreshAvailableMonths(now: Date = Date()) async {
        let stored = await recapStore.availableMonths()
        let completed = RecapWindow.mostRecentCompleted(asOf: now)
        let inProgress = RecapWindow.current(asOf: now)
        availableMonths = Array(Set(stored + [completed, inProgress])).sorted(by: >)
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
        let composer = makeComposer()

        buildTask = Task { [weak self] in
            guard let self else { return }
            // Paint whatever is already stored before touching the database.
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
                    self.isPolishing = self.isEditorialEnabled && !deck.sealState.isSealed
                case let .voiced(deck):
                    withAnimation(DesignSystem.Animation.gentle) {
                        self.recap = deck
                    }
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

    // MARK: - Composer

    private var isEditorialEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.aiToggleKey)
    }

    private func makeComposer() -> RecapComposer {
        // The editorial layer is opt-in. With it off the composer gets an author
        // that never answers, which is a supported state rather than a
        // degraded one — the deck is complete either way.
        let author: any RecapVoiceAuthor = isEditorialEnabled
            ? MacRecapVoiceAuthor(bridge: bridge, enabledBackends: enabledBackends())
            : RecapVoiceAuthorUnavailable()

        return RecapComposer(
            source: MacRecapSource(dataStore: dataStore),
            historyStore: historyStore,
            recapStore: recapStore,
            author: author
        )
    }

    // MARK: - Paths

    private static func recapDirectory() throws -> URL {
        let manager = FileManager.default
        let url = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("OpenBurnBar", isDirectory: true)
        .appendingPathComponent("Recap", isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
