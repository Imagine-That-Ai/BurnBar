#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore

/// Captures local Mac screenshots for Computer Use approval and audit
/// evidence. The audit chain stores content hashes; the PNG files live
/// beside the session log so a human can later compare the artifact with
/// the recorded hash.
public final class MacScreenshotService: @unchecked Sendable {
    public struct Capture: Sendable, Equatable {
        public let pngURL: URL
        public let pngData: Data
        public let sha256Hex: String
        public let width: Int
        public let height: Int
    }

    public enum CaptureError: Error, Sendable, Equatable {
        case noMainDisplayImage
        case pngEncodingFailed
    }

    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(
        baseDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public func captureMainDisplay(
        label: String,
        sessionId: ComputerUseSessionID,
        entryIndexHint: Int
    ) throws -> Capture {
        let displayId = CGMainDisplayID()
        guard let image = CGDisplayCreateImage(displayId) else {
            throw CaptureError.noMainDisplayImage
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.pngEncodingFailed
        }

        let directory = baseDirectory
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = "\(String(format: "%06d", entryIndexHint))-\(sanitized(label)).png"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try png.write(to: url, options: [.atomic])

        return Capture(
            pngURL: url,
            pngData: png,
            sha256Hex: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            width: image.width,
            height: image.height
        )
    }

    private func sanitized(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = label.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let joined = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return joined.isEmpty ? "capture" : joined
    }
}
#endif
