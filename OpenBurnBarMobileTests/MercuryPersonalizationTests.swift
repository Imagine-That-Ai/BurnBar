import XCTest
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

    func testTransferHistoryDebouncedPersistenceCompletesOffMainActor() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-history-debounced-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = MercuryTransferHistoryStore(fileURL: tempURL)
        store.append(makeEntry(id: "debounced", connectionID: "mac-async"))

        try await Task.sleep(for: .milliseconds(500))

        let reloaded = MercuryTransferHistoryStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.entries.map(\.id), ["debounced"])
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
        XCTAssertEqual(store.entries.first?.id, "dupe")
        XCTAssertEqual(Set(store.entries.map(\.id)).count, 1)
    }

    func testTransferHistoryDedupesAllExistingRowsOnAppendOfSameID() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-history-dedupe-existing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let staleDuplicates = [
            makeEntry(id: "dupe", connectionID: "mac-old-a"),
            makeEntry(id: "dupe", connectionID: "mac-old-b")
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(staleDuplicates).write(to: tempURL)

        let store = MercuryTransferHistoryStore(fileURL: tempURL)
        store.append(makeEntry(id: "dupe", connectionID: "mac-latest"))

        XCTAssertEqual(store.entries.map(\.id), ["dupe"])
        XCTAssertEqual(store.entries.first?.connectionID, "mac-latest")
    }

    func testWallpaperAccentSamplerReturnsNilForEmptyOrInvalidPayloads() {
        XCTAssertNil(WallpaperAccentSampler.dominantAccent(fromBase64: nil))
        XCTAssertNil(WallpaperAccentSampler.dominantAccent(fromBase64: ""))
        XCTAssertNil(WallpaperAccentSampler.dominantAccent(fromBase64: "not-a-real-base64-payload"))
        XCTAssertNil(
            WallpaperAccentSampler.dominantAccent(
                fromImageData: Data([0x89, 0x50, 0x4E, 0x47])
            )
        )
        XCTAssertNil(
            WallpaperAccentSampler.dominantAccent(
                fromImageData: Data(repeating: 0, count: 512 * 1_024 + 1)
            )
        )
        XCTAssertNil(
            WallpaperAccentSampler.dominantAccent(
                fromBase64: String(repeating: "A", count: 700_000)
            )
        )
    }

    func testWallpaperAccentSamplerReturnsAccentForRedSquare() throws {
        let accent = try XCTUnwrap(
            WallpaperAccentSampler.dominantAccent(fromBase64: Self.redPixelPNGBase64),
            "Should sample a color from a valid PNG payload"
        )
        let resolved = accent.resolve(in: EnvironmentValues())
        XCTAssertGreaterThan(resolved.red, resolved.green)
        XCTAssertGreaterThan(resolved.red, resolved.blue)
    }

    func testWallpaperAccentSamplerHandlesPNGJPEGAndTransparency() throws {
        let greenJPEG = try encodedImage(
            width: 2,
            height: 2,
            rgba: Array(repeating: [UInt8(20), 230, 30, 255], count: 4).flatMap { $0 },
            type: .jpeg
        )
        let greenAccent = try XCTUnwrap(
            WallpaperAccentSampler.dominantAccent(fromImageData: greenJPEG)
        ).resolve(in: EnvironmentValues())
        XCTAssertGreaterThan(greenAccent.green, greenAccent.red)
        XCTAssertGreaterThan(greenAccent.green, greenAccent.blue)

        let mixedPNG = try encodedImage(
            width: 2,
            height: 1,
            rgba: [
                255, 0, 0, 255,
                0, 0, 255, 255
            ],
            type: .png
        )
        let mixedAccent = try XCTUnwrap(
            WallpaperAccentSampler.dominantAccent(fromImageData: mixedPNG)
        ).resolve(in: EnvironmentValues())
        XCTAssertGreaterThan(mixedAccent.red, mixedAccent.green)
        XCTAssertGreaterThan(mixedAccent.blue, mixedAccent.green)

        let transparentPNG = try encodedImage(
            width: 2,
            height: 2,
            rgba: Array(repeating: UInt8(0), count: 16),
            type: .png
        )
        XCTAssertNil(
            WallpaperAccentSampler.dominantAccent(fromImageData: transparentPNG)
        )
    }

    func testWallpaperAccentSamplerRemainsStableAcrossRepeatedSamples() {
        var reference: Color.Resolved?
        for _ in 0..<100 {
            let resolved = WallpaperAccentSampler.dominantAccent(
                fromBase64: Self.redPixelPNGBase64
            )?.resolve(in: EnvironmentValues())
            XCTAssertNotNil(
                resolved
            )
            if let reference, let resolved {
                XCTAssertEqual(resolved.red, reference.red, accuracy: 0.001)
                XCTAssertEqual(resolved.green, reference.green, accuracy: 0.001)
                XCTAssertEqual(resolved.blue, reference.blue, accuracy: 0.001)
                XCTAssertEqual(resolved.opacity, reference.opacity, accuracy: 0.001)
            } else {
                reference = resolved
            }
        }
    }

    func testWallpaperAccentSamplerRejectsOversizedAdvertisedDimensions() throws {
        // A tiny, highly compressible payload can advertise enormous source
        // dimensions while staying under the encoded-byte cap. The sampler
        // must reject it from the image properties alone, before decoding.
        let oversized = try pngAdvertisingDimensions(width: 20_000, height: 20_000)
        XCTAssertLessThanOrEqual(oversized.count, 512 * 1_024)
        XCTAssertNil(WallpaperAccentSampler.dominantAccent(fromImageData: oversized))
        XCTAssertNil(
            WallpaperAccentSampler.dominantAccent(
                fromBase64: oversized.base64EncodedString()
            )
        )

        // One oversized axis is enough to reject.
        let wide = try pngAdvertisingDimensions(width: 20_000, height: 1)
        XCTAssertNil(WallpaperAccentSampler.dominantAccent(fromImageData: wide))
    }

    func testWallpaperAccentSamplerWeightsPartiallyTransparentPixelsByAlpha() throws {
        let alphaWeightedPNG = try encodedImage(
            width: 2,
            height: 1,
            rgba: [
                255, 0, 0, 255,
                0, 0, 128, 128
            ],
            type: .png
        )
        let accent = try XCTUnwrap(
            WallpaperAccentSampler.dominantAccent(fromImageData: alphaWeightedPNG)
        ).resolve(in: EnvironmentValues())

        XCTAssertGreaterThan(accent.red, accent.blue)
        XCTAssertGreaterThan(accent.blue, accent.green)
    }

    // MARK: - Helpers

    private func encodedImage(
        width: Int,
        height: Int,
        rgba: [UInt8],
        type: UTType
    ) throws -> Data {
        XCTAssertEqual(rgba.count, width * height * 4)
        let sourceData = Data(rgba)
        let provider = try XCTUnwrap(CGDataProvider(data: sourceData as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let image = try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                type.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return Data(bytes: output.bytes, count: output.length)
    }

    /// Returns the 1x1 red PNG with its IHDR width/height rewritten (and the
    /// chunk CRC fixed up) so ImageIO reports the advertised dimensions from
    /// the header even though the pixel data never matches them.
    private func pngAdvertisingDimensions(width: UInt32, height: UInt32) throws -> Data {
        var data = try XCTUnwrap(Data(base64Encoded: Self.redPixelPNGBase64))
        // PNG layout: 8-byte signature, 4-byte IHDR length, 4-byte "IHDR"
        // type (offsets 12-15), 13 bytes of IHDR data (width at 16, height
        // at 20), then a 4-byte CRC over type + data (offsets 29-32).
        XCTAssertGreaterThan(data.count, 33)
        func writeBigEndian(_ value: UInt32, at offset: Int) {
            data[offset] = UInt8((value >> 24) & 0xFF)
            data[offset + 1] = UInt8((value >> 16) & 0xFF)
            data[offset + 2] = UInt8((value >> 8) & 0xFF)
            data[offset + 3] = UInt8(value & 0xFF)
        }
        writeBigEndian(width, at: 16)
        writeBigEndian(height, at: 20)
        writeBigEndian(Self.crc32(data[12..<29]), at: 29)
        return data
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

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

    private static let redPixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
}
