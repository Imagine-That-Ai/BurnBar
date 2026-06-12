import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import OpenBurnBarMobile

/// Guards the async thumbnail path behind the Mercury recent-transfers card:
/// thumbnails must stay tiny (no full-resolution decode), cache by
/// path + mtime, and bake EXIF orientation into the pixels so rotated
/// photos keep parity with the old `UIImage(contentsOfFile:)` rendering.
final class MercuryTransferThumbnailCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MercuryTransferThumbnailCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    func testThumbnailIsDownscaledToMaxPixelSize() async throws {
        let url = tempDir.appendingPathComponent("landscape.jpg")
        try writeJPEG(width: 1200, height: 800, to: url)

        let cache = MercuryTransferThumbnailCache()
        let result = await cache.thumbnail(for: url)
        let image = try XCTUnwrap(result)

        XCTAssertEqual(image.cgImage?.width, MercuryTransferThumbnailCache.maxPixelSize)
        XCTAssertEqual(image.cgImage?.height, 96)
    }

    func testExifOrientationIsBakedIntoThumbnailPixels() async throws {
        // Orientation .right (EXIF 6): raw 1200×800 pixels display as
        // 800×1200. `UIImage(contentsOfFile:)` honored the tag
        // automatically, so the replacement must too or rotated photos
        // render sideways.
        let url = tempDir.appendingPathComponent("rotated.jpg")
        try writeJPEG(width: 1200, height: 800, orientation: .right, to: url)

        let cache = MercuryTransferThumbnailCache()
        let result = await cache.thumbnail(for: url)
        let image = try XCTUnwrap(result)

        XCTAssertEqual(image.cgImage?.width, 96)
        XCTAssertEqual(image.cgImage?.height, MercuryTransferThumbnailCache.maxPixelSize)
    }

    func testSecondLookupReturnsCachedInstance() async throws {
        let url = tempDir.appendingPathComponent("square.jpg")
        try writeJPEG(width: 600, height: 600, to: url)

        let cache = MercuryTransferThumbnailCache()
        let firstResult = await cache.thumbnail(for: url)
        let first = try XCTUnwrap(firstResult)
        let secondResult = await cache.thumbnail(for: url)
        let second = try XCTUnwrap(secondResult)

        XCTAssertIdentical(first, second)
    }

    func testModifiedFileRegeneratesThumbnail() async throws {
        let url = tempDir.appendingPathComponent("replaced.jpg")
        try writeJPEG(width: 600, height: 400, to: url)

        let cache = MercuryTransferThumbnailCache()
        let firstResult = await cache.thumbnail(for: url)
        let first = try XCTUnwrap(firstResult)

        try writeJPEG(width: 400, height: 600, to: url)
        // Force a distinct cache key even on filesystems with coarse
        // mtime resolution.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: url.path
        )

        let secondResult = await cache.thumbnail(for: url)
        let second = try XCTUnwrap(secondResult)
        XCTAssertNotIdentical(first, second)
        XCTAssertGreaterThan(second.size.height, second.size.width)
    }

    func testMissingFileReturnsNil() async {
        let url = tempDir.appendingPathComponent("missing.jpg")
        let cache = MercuryTransferThumbnailCache()
        let image = await cache.thumbnail(for: url)
        XCTAssertNil(image)
    }

    func testNonImageFileReturnsNil() async throws {
        let url = tempDir.appendingPathComponent("not-an-image.jpg")
        try Data("plain text".utf8).write(to: url)

        let cache = MercuryTransferThumbnailCache()
        let image = await cache.thumbnail(for: url)
        XCTAssertNil(image)
    }

    // MARK: - Helpers

    private func writeJPEG(
        width: Int,
        height: Int,
        orientation: CGImagePropertyOrientation? = nil,
        to url: URL
    ) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try XCTUnwrap(context.makeImage())

        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation.rawValue
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
