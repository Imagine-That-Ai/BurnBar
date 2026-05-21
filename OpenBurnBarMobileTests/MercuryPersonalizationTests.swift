import XCTest
import SwiftUI
@testable import OpenBurnBarMobile

@MainActor
final class MercuryPersonalizationTests: XCTestCase {
    func testDefaultForFirstRunRoundTripsThroughCodable() throws {
        let original = MercuryDevicePersonalization.defaultForFirstRun
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MercuryDevicePersonalization.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripWithEveryAvatarKind() throws {
        var personalization = MercuryDevicePersonalization.defaultForFirstRun
        personalization.nickname = "Studio Mac"
        personalization.accent = .whimsy
        personalization.avatar = .photo(Data([0x89, 0x50, 0x4E, 0x47]))
        personalization.background = .solid
        personalization.actionOrder = [.sendFile, .mirror]
        personalization.badges = [.battery, .hostname]
        personalization.haptics = .crisp
        personalization.showHermesSquareTile = false
        personalization.mimicLoginBackground = false

        let data = try JSONEncoder().encode(personalization)
        let decoded = try JSONDecoder().decode(MercuryDevicePersonalization.self, from: data)
        XCTAssertEqual(decoded, personalization)
    }

    func testNormalizedActionOrderRemovesDuplicatesAndPreservesFirstAppearance() {
        var personalization = MercuryDevicePersonalization.defaultForFirstRun
        personalization.actionOrder = [.mirror, .mirror, .call, .sendFile, .call]
        XCTAssertEqual(personalization.normalizedActionOrder(), [.mirror, .call, .sendFile])
    }

    func testNormalizedBadgesEmptyFallsBackToDefaults() {
        var personalization = MercuryDevicePersonalization.defaultForFirstRun
        personalization.badges = []
        XCTAssertEqual(personalization.normalizedBadges(), [.architecture, .os])
    }

    func testNormalizedBadgesCapsAtTwo() {
        var personalization = MercuryDevicePersonalization.defaultForFirstRun
        personalization.badges = [.battery, .hostname, .ip, .app]
        XCTAssertEqual(personalization.normalizedBadges(), [.battery, .hostname])
    }

    func testPersonalizationStoreBindingIsolatesPerConnectionID() {
        let defaults = UserDefaults(suiteName: "mercury.personalization.tests.\(UUID().uuidString)")!
        let store = MercuryPersonalizationStore(defaults: defaults)

        let macA = "mac-a"
        let macB = "mac-b"

        store.mutate(connectionID: macA) { $0.nickname = "Studio Mac" }
        store.mutate(connectionID: macB) { $0.nickname = "Travel Mac" }

        XCTAssertEqual(store.snapshot(for: macA).nickname, "Studio Mac")
        XCTAssertEqual(store.snapshot(for: macB).nickname, "Travel Mac")
    }

    func testPersonalizationStoreMigratesLegacyAppStorageKeys() {
        let defaults = UserDefaults(suiteName: "mercury.personalization.legacy.\(UUID().uuidString)")!
        defaults.set(false, forKey: "mercuryPinnedTileEnabled")
        defaults.set(false, forKey: "mercuryMimicLoginBackground")

        let store = MercuryPersonalizationStore(defaults: defaults)
        let snapshot = store.snapshot(for: "fresh-mac")

        XCTAssertFalse(snapshot.showHermesSquareTile)
        XCTAssertFalse(snapshot.mimicLoginBackground)
    }

    func testEffectiveNicknameFallsBackToPeerName() {
        let defaults = UserDefaults(suiteName: "mercury.personalization.fallback.\(UUID().uuidString)")!
        let store = MercuryPersonalizationStore(defaults: defaults)
        XCTAssertEqual(
            store.effectiveNickname(for: "mac-c", fallback: "Alberto's MacBook Pro"),
            "Alberto's MacBook Pro"
        )

        store.mutate(connectionID: "mac-c") { $0.nickname = " " }
        // Whitespace-only nicknames are treated as unset.
        XCTAssertEqual(
            store.effectiveNickname(for: "mac-c", fallback: "Alberto's MacBook Pro"),
            "Alberto's MacBook Pro"
        )

        store.mutate(connectionID: "mac-c") { $0.nickname = "Studio" }
        XCTAssertEqual(
            store.effectiveNickname(for: "mac-c", fallback: "Alberto's MacBook Pro"),
            "Studio"
        )
    }

    func testNicknameSuggestionsStripsPossessivePrefix() {
        let store = MercuryPersonalizationStore(defaults: UserDefaults(suiteName: "mercury.suggestions.\(UUID().uuidString)")!)
        let suggestions = store.nicknameSuggestions(for: "Alberto's MacBook Pro")
        XCTAssertTrue(suggestions.contains("MacBook Pro"), "Expected suggestion to strip possessive — got \(suggestions)")
        XCTAssertFalse(suggestions.contains("Alberto's MacBook Pro"), "Should not suggest the original full name")
    }

    func testTransferHistoryAppendTrimsToCap() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let store = MercuryTransferHistoryStore(fileURL: tempURL)

        for i in 0..<60 {
            store.append(
                MercuryTransferHistoryEntry(
                    id: "id-\(i)",
                    connectionID: "mac-z",
                    direction: .sent,
                    filename: "File-\(i).bin",
                    mime: "application/octet-stream",
                    sizeBytes: 1024,
                    completedAt: Date().addingTimeInterval(TimeInterval(i)),
                    bytesPerSecond: nil,
                    didResume: false,
                    localURL: nil
                )
            )
        }

        XCTAssertLessThanOrEqual(store.entries.count, MercuryTransferHistoryStore.globalCap)
        // Newest is at the front of the array.
        XCTAssertEqual(store.entries.first?.id, "id-59")
    }

    func testTransferHistoryPersistsAndReloads() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-history-reload-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            let store = MercuryTransferHistoryStore(fileURL: tempURL)
            store.append(
                MercuryTransferHistoryEntry(
                    id: "alpha",
                    connectionID: "mac-r",
                    direction: .received,
                    filename: "Photo.png",
                    mime: "image/png",
                    sizeBytes: 2_048,
                    completedAt: Date(),
                    bytesPerSecond: 102_400,
                    didResume: false,
                    localURL: nil
                )
            )
            store.flush()
        }

        let reloaded = MercuryTransferHistoryStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.entries.first?.id, "alpha")
        XCTAssertEqual(reloaded.recent(for: "mac-r").first?.filename, "Photo.png")
        XCTAssertEqual(reloaded.totalCount(for: "mac-r"), 1)
    }

    func testTransferHistoryRecentScopesByConnectionID() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-history-scope-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let store = MercuryTransferHistoryStore(fileURL: tempURL)

        store.append(makeEntry(id: "1", connectionID: "mac-a"))
        store.append(makeEntry(id: "2", connectionID: "mac-b"))
        store.append(makeEntry(id: "3", connectionID: "mac-a"))

        XCTAssertEqual(store.recent(for: "mac-a", limit: 5).map(\.id), ["3", "1"])
        XCTAssertEqual(store.recent(for: "mac-b", limit: 5).map(\.id), ["2"])
    }

    func testTransferHistoryDedupesOnAppendOfSameID() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-history-dedupe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let store = MercuryTransferHistoryStore(fileURL: tempURL)

        store.append(makeEntry(id: "dupe", connectionID: "mac-q"))
        store.append(makeEntry(id: "dupe", connectionID: "mac-q"))
        store.append(makeEntry(id: "dupe", connectionID: "mac-q"))

        XCTAssertEqual(store.entries.count, 1)
    }

    func testWallpaperAccentSamplerReturnsNilForEmptyOrInvalidPayloads() {
        XCTAssertNil(WallpaperAccentSampler.dominantAccent(fromBase64: nil))
        XCTAssertNil(WallpaperAccentSampler.dominantAccent(fromBase64: ""))
        XCTAssertNil(WallpaperAccentSampler.dominantAccent(fromBase64: "not-a-real-base64-payload"))
    }

    func testWallpaperAccentSamplerReturnsAccentForRedSquare() throws {
        let red = try makePixelImageBase64(red: 250, green: 40, blue: 40)
        let accent = WallpaperAccentSampler.dominantAccent(fromBase64: red)
        XCTAssertNotNil(accent, "Should sample a color from a valid PNG payload")
    }

    // MARK: - Helpers

    private func makeEntry(id: String, connectionID: String) -> MercuryTransferHistoryEntry {
        MercuryTransferHistoryEntry(
            id: id,
            connectionID: connectionID,
            direction: .sent,
            filename: "\(id).bin",
            mime: "application/octet-stream",
            sizeBytes: 32,
            completedAt: Date(),
            bytesPerSecond: nil,
            didResume: false,
            localURL: nil
        )
    }

    private func makePixelImageBase64(red: UInt8, green: UInt8, blue: UInt8) throws -> String {
        // 1×1 RGBA bitmap → CGImage → PNG → base64.
        let pixels: [UInt8] = [red, green, blue, 255]
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        let cgImage = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
        guard let cgImage,
              let image = UIImage(cgImage: cgImage).pngData() else {
            throw NSError(domain: "MercuryPersonalizationTests", code: -1)
        }
        return image.base64EncodedString()
    }
}
