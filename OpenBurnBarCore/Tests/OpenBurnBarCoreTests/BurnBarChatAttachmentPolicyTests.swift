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
                "image/webp"
            ]
        )
        XCTAssertFalse(BurnBarChatAttachmentPolicy.allowedMimeTypes.contains("audio/mpeg"))
    }
}
