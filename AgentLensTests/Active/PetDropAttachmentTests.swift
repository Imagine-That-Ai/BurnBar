import XCTest
import AppKit
import OpenBurnBarCore
@testable import OpenBurnBar

/// File drag-and-drop onto the floating 3D pet / 2D avatar. The drop stages the
/// file as a chat attachment on the **shared** `ChatSessionController` (via the
/// pet's `PetChatController` forwarders), enforces the existing per-kind size
/// caps, and the gate keeps empty panel padding drop-through. The pet is the
/// single drop target that works over any app/Space because it already floats
/// above all of them.
@MainActor
final class PetDropAttachmentTests: XCTestCase {

    // MARK: Acceptance gate

    func test_acceptsDrag_returnsCopyForFileURLOnVisibleContent() throws {
        let url = try writeTempFile(named: "tiny.png", data: makeTinyPNG())
        defer { try? FileManager.default.removeItem(at: url) }

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let info = SyntheticDragInfo(pasteboard: pasteboard(with: [url]), location: .zero)

        let delegate = PetAttachmentDropDelegate(
            onDropFile: { _ in },
            onDropImage: { _, _ in },
            visibleContentGate: { _, _ in true } // always visible (renderer hit)
        )

        XCTAssertEqual(delegate.acceptsDrag(info: info, in: view), .copy)
    }

    func test_acceptsDrag_returnsEmptyForNonVisibleContent() throws {
        let url = try writeTempFile(named: "tiny.png", data: makeTinyPNG())
        defer { try? FileManager.default.removeItem(at: url) }

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let info = SyntheticDragInfo(pasteboard: pasteboard(with: [url]), location: .zero)

        let delegate = PetAttachmentDropDelegate(
            onDropFile: { _ in },
            onDropImage: { _, _ in },
            visibleContentGate: { _, _ in false } // empty padding → drop-through
        )

        XCTAssertEqual(delegate.acceptsDrag(info: info, in: view), [])
    }

    func test_acceptsDrag_returnsEmptyForNonFilePasteboard() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let pb = makePasteboard()
        pb.setString("just text", forType: .string)
        let info = SyntheticDragInfo(pasteboard: pb, location: .zero)

        let delegate = PetAttachmentDropDelegate(
            onDropFile: { _ in },
            onDropImage: { _, _ in },
            visibleContentGate: { _, _ in true }
        )

        XCTAssertEqual(delegate.acceptsDrag(info: info, in: view), [])
    }

    // MARK: Perform — staging via the shared controller

    func test_performDrag_stagesURLAttachmentViaSharedController() throws {
        let session = try makeSharedChatSession()
        let pet = attachPet(to: session)

        let url = try writeTempFile(named: "tiny.png", data: makeTinyPNG())
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(session.pendingAttachments.isEmpty)
        pet.handleDroppedFile(url)

        XCTAssertEqual(session.pendingAttachments.count, 1)
        let attachment = try XCTUnwrap(session.pendingAttachments.first)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.displayName, "tiny.png")
        XCTAssertNil(session.attachmentError)
    }

    func test_performDrag_stagesNSImageAttachmentWithSuggestedName() throws {
        let session = try makeSharedChatSession()
        let pet = attachPet(to: session)

        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        XCTAssertTrue(session.pendingAttachments.isEmpty)
        pet.handleDroppedImage(image, suggestedName: "dropped.png")

        XCTAssertEqual(session.pendingAttachments.count, 1)
        let attachment = try XCTUnwrap(session.pendingAttachments.first)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertNil(session.attachmentError)
    }

    func test_performDrag_oversizedFileSetsAttachmentErrorAndDoesNotStage() throws {
        let session = try makeSharedChatSession()
        let pet = attachPet(to: session)

        // 21 MB synthetic PNG-ish bytes (header gives .image kind; 20 MB cap rejects).
        var blob = Data(repeating: 0xFF, count: 21 * 1024 * 1024)
        let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        blob.replaceSubrange(0..<pngHeader.count, with: pngHeader)
        let url = try writeTempFile(named: "huge.png", data: blob)
        defer { try? FileManager.default.removeItem(at: url) }

        pet.handleDroppedFile(url)

        XCTAssertTrue(session.pendingAttachments.isEmpty)
        XCTAssertNotNil(session.attachmentError)
    }

    // MARK: Feedback — react + open bubble

    func test_performDrag_drivesReactAndOpensBubble() throws {
        let session = try makeSharedChatSession()
        let pet = attachPet(to: session)
        let chat = try XCTUnwrap(pet.chat)

        let url = try writeTempFile(named: "tiny.png", data: makeTinyPNG())
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(chat.isOpen)
        pet.handleDroppedFile(url)

        XCTAssertEqual(pet.currentState, PetLogicalState.react.rawValue)
        XCTAssertTrue(chat.isOpen)
    }

    // MARK: Safety — no chat attached

    func test_performDrag_noChatAttached_drivesReactAndDoesNotCrash() throws {
        let pet = PetCompanionController() // ambient-only: no attachChat

        let url = try writeTempFile(named: "tiny.png", data: makeTinyPNG())
        defer { try? FileManager.default.removeItem(at: url) }

        // No crash; the pet still reacts so the drop is never inert.
        pet.handleDroppedFile(url)
        XCTAssertEqual(pet.currentState, PetLogicalState.react.rawValue)
    }

    // MARK: PetChatController forwarders

    func test_petChatController_stageAttachmentFromURL_roundTrips() throws {
        let session = try makeSharedChatSession()
        let pet = attachPet(to: session)
        let chat = try XCTUnwrap(pet.chat)

        let url = try writeTempFile(named: "notes.md", data: "# Hello".data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: url) }

        chat.stageAttachment(from: url)
        XCTAssertEqual(chat.pendingAttachments.count, 1)
        XCTAssertEqual(chat.pendingAttachments.first?.displayName, "notes.md")
    }

    func test_petChatController_removeAttachment_dropsFromPending() throws {
        let session = try makeSharedChatSession()
        let pet = attachPet(to: session)
        let chat = try XCTUnwrap(pet.chat)

        let url = try writeTempFile(named: "notes.md", data: "# Hello".data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: url) }

        chat.stageAttachment(from: url)
        let id = try XCTUnwrap(chat.pendingAttachments.first?.id)
        chat.removeAttachment(id)
        XCTAssertTrue(chat.pendingAttachments.isEmpty)
    }

    // MARK: Drop delegate perform (pasteboard-driven, no live drag session)

    func test_dropDelegate_performDragStagesURLViaClosures() throws {
        let url = try writeTempFile(named: "tiny.png", data: makeTinyPNG())
        defer { try? FileManager.default.removeItem(at: url) }

        var stagedURL: URL?
        var stagedImage: (NSImage, String?)?
        let delegate = PetAttachmentDropDelegate(
            onDropFile: { stagedURL = $0 },
            onDropImage: { image, name in stagedImage = (image, name) },
            visibleContentGate: { _, _ in true }
        )

        let info = SyntheticDragInfo(pasteboard: pasteboard(with: [url]), location: .zero)

        XCTAssertTrue(delegate.performDrag(info: info))
        XCTAssertEqual(stagedURL, url)
        XCTAssertNil(stagedImage) // file URL present → image not double-staged
    }

    // MARK: Helpers

    private func makeSharedChatSession() throws -> ChatSessionController {
        let dataStore = try makeDiscoveryInMemoryStore()
        return ChatSessionController(
            dataStore: dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )
    }

    private func attachPet(to session: ChatSessionController) -> PetCompanionController {
        let pet = PetCompanionController()
        pet.attachChat(session)
        return pet
    }

    private func pasteboard(with urls: [URL]) -> NSPasteboard {
        let pb = makePasteboard()
        pb.writeObjects(urls as [NSPasteboardWriting])
        return pb
    }

    private func writeTempFile(named name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// 1×1 transparent PNG generated via `NSBitmapImageRep` so the bytes are
    /// always valid (no hardcoded base64 that can get mangled).
    private func makeTinyPNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        )
        rep?.setColor(NSColor.clear, atX: 0, y: 0)
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    /// `NSPasteboard()` uses the class-cluster `init` which hits
    /// `+allocWithZone:` and crashes under the test bundle host. A named
    /// pasteboard backed by the system cache is the safe construction.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("pet-drop-test-\(UUID().uuidString)"))
    }
}

// MARK: - SyntheticDragInfo

/// Minimal `PetDragInfo` conformer so the drop delegate's pure pasteboard-driven
/// methods are exercisable without a live AppKit drag session. AppKit's own
/// `NSDraggingInfo` is not constructible in tests and its required-member
/// surface varies across SDK versions; this shim supplies the two properties
/// the delegate reads (`draggingPasteboard` + `draggingLocation`).
@MainActor
private final class SyntheticDragInfo: PetDragInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint

    init(pasteboard: NSPasteboard, location: NSPoint) {
        self.draggingPasteboard = pasteboard
        self.draggingLocation = location
    }
}
