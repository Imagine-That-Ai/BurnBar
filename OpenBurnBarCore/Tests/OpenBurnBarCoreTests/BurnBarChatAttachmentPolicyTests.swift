import XCTest
@testable import OpenBurnBarKernel

final class BurnBarChatAttachmentPolicyTests: XCTestCase {
    func testCanonicalMimeTypeInfersAllowlistedTextDocuments() {
        XCTAssertEqual(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "notes.md",
                mimeType: "application/octet-stream"
            ),
            "text/markdown"
        )
        XCTAssertEqual(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "data.json",
                mimeType: "application/json"
            ),
            "application/json"
        )
        XCTAssertEqual(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "brief.pdf",
                mimeType: "application/pdf"
            ),
            "application/pdf"
        )
    }

    func testCanonicalMimeTypeRejectsUnsupportedOrMismatchedFiles() {
        XCTAssertNil(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "notes.md",
                mimeType: "application/pdf"
            )
        )
        XCTAssertNil(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "program.exe",
                mimeType: "application/octet-stream"
            )
        )
        XCTAssertNil(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "../notes.md",
                mimeType: "text/markdown"
            )
        )
        XCTAssertFalse(BurnBarChatAttachmentPolicy.isSafeFileName("notes/secret.md"))
    }

    func testCanonicalMimeTypeAcceptsModelAuthorizedImageInputs() {
        XCTAssertEqual(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "screenshot.PNG",
                mimeType: "application/octet-stream"
            ),
            "image/png"
        )
        XCTAssertEqual(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "photo.jpeg",
                mimeType: "image/jpeg"
            ),
            "image/jpeg"
        )
        XCTAssertEqual(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "diagram.webp",
                mimeType: "image/webp"
            ),
            "image/webp"
        )
    }

    func testCanonicalMimeTypeAcceptsModelAuthorizedAudioInputs() {
        XCTAssertEqual(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "voice.m4a",
                mimeType: "application/octet-stream"
            ),
            "audio/mp4"
        )
        XCTAssertEqual(
            BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: "voice.mp3",
                mimeType: "audio/mpeg"
            ),
            "audio/mpeg"
        )
    }

    func testLinuxTransportBudgetIsTenMiBAndListsOnlySupportedChatTypes() {
        XCTAssertEqual(BurnBarChatAttachmentPolicy.maxBytes, 10 * 1024 * 1024)
        XCTAssertEqual(
            BurnBarChatAttachmentPolicy.allowedMimeTypes,
            [
                "text/plain",
                "text/markdown",
                "text/csv",
                "application/json",
                "application/pdf",
                "image/png",
                "image/jpeg",
                "image/webp",
                "audio/mpeg",
                "audio/wav",
                "audio/mp4",
                "audio/aac",
                "audio/flac",
                "audio/aiff"
            ]
        )
        XCTAssertTrue(BurnBarChatAttachmentPolicy.allowedMimeTypes.contains("audio/mpeg"))
    }
}
