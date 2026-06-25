import AppKit
import UniformTypeIdentifiers

// MARK: - PetDragInfo

/// Minimal drag-session read surface the drop delegate consumes: just the
/// pasteboard + the cursor location. A real AppKit `NSDraggingInfo` is bridged
/// into it by ``AnyDragInfo`` in `PetDropHostingView.swift` (Swift doesn't honor
/// an `extension NSDraggingInfo: PetDragInfo {}` conformance when the value
/// arrives as the `any NSDraggingInfo` existential from an AppKit override).
/// Tests build a trivial conformer so the acceptance/perform logic is
/// exercisable without a live drag session (`NSDraggingInfo` itself is not
/// constructible in tests and its required-member surface varies across SDK
/// versions).
@MainActor
protocol PetDragInfo {
    var draggingPasteboard: NSPasteboard { get }
    var draggingLocation: NSPoint { get }
}

// MARK: - PetAttachmentDropDelegate

/// The file drag-and-drop brain for the floating pet. Installed by
/// ``PetCompanionController`` on every freshly mounted renderer view (the 3D
/// `SCNView` and 2D `SKView`) alongside the click gesture, so a drop anywhere on
/// the desktop pet stages the file as a chat attachment on the **shared**
/// ``ChatSessionController`` (Ground Truth #2 — no duplicate agent layer).
///
/// The delegate is pure pasteboard-driven: the acceptance/perform methods read
/// ``PetDragInfo``-driven pasteboard data directly, so the logic is unit-testable
/// without a live AppKit drag session (tests build a synthetic ``PetDragInfo``
/// conformer + call `acceptsDrag`/`performDrag`).
///
/// **Drop-through gate.** A drop only "sticks" when it lands on visible pet
/// content (reusing the renderer's existing ``PetRenderer/containsVisibleContent(at:)``
/// gate, the same test the click gesture uses). Empty panel pixels return `[]`
/// from `draggingEntered`, so AppKit forwards the drag to whatever window is
/// under the pet — the pet never swallows a drop aimed at another app.
@MainActor
final class PetAttachmentDropDelegate: NSObject {

    /// Pasteboard types the pet accepts, mirroring the chat composer's drop set
    /// (``ChatInputRow`` accepts `[.fileURL, .image, .pdf, .url]`) plus the raw
    /// image pasteboard types it already handles. Anything else → drop-through.
    static let acceptableTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .URL, .png, .tiff, .pdf
    ]

    /// Called by the controller when a file URL is dropped. Routes the URL into
    /// `ChatSessionController.addAttachment(from:)` (which imports via
    /// ``HermesAttachmentLoader``, enforces per-kind size caps, copies into the
    /// per-thread workspace, and makes a thumbnail).
    var onDropFile: (URL) -> Void

    /// Called by the controller when an in-memory `NSImage` is dropped (e.g. a
    /// screenshot dragged from another app). Routes the image into
    /// `ChatSessionController.addAttachment(image:suggestedName:)` (which writes
    /// a PNG into the workspace + sizes it).
    var onDropImage: (NSImage, String?) -> Void

    /// Reuses the renderer's visible-content test so a drop only sticks on pet
    /// pixels (empty panel padding stays drop-through). Mirrors the click
    /// gesture's `PetClickGestureGate` gate.
    var visibleContentGate: (CGPoint, NSView) -> Bool

    init(
        onDropFile: @escaping (URL) -> Void,
        onDropImage: @escaping (NSImage, String?) -> Void,
        visibleContentGate: @escaping (CGPoint, NSView) -> Bool
    ) {
        self.onDropFile = onDropFile
        self.onDropImage = onDropImage
        self.visibleContentGate = visibleContentGate
        super.init()
    }

    // MARK: Acceptance (draggingEntered / draggingUpdated)

    /// Returns `.copy` when the drop point hits visible pet content AND the
    /// pasteboard carries at least one file URL or image; `[]` (drop-through)
    /// otherwise. Pure: no side effects, safe to call from tests.
    func acceptsDrag(info: PetDragInfo, in view: NSView) -> NSDragOperation {
        let point = info.draggingLocation
        guard visibleContentGate(point, view) else { return [] }
        guard pasteboardHasAcceptableItem(info.draggingPasteboard) else { return [] }
        return .copy
    }

    // MARK: Perform (performDragOperation)

    /// Reads the pasteboard, dispatches each accepted URL/image to the import
    /// closures, and returns `true` when at least one item landed. Returns `false`
    /// (drop-through) when the pasteboard carries nothing acceptable.
    func performDrag(info: PetDragInfo) -> Bool {
        let pasteboard = info.draggingPasteboard
        var handled = false

        // File URLs first (most common: Finder drag, path bar drag).
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            for url in urls {
                onDropFile(url)
                handled = true
            }
        }

        // In-memory images (screenshot drag, image-from-browser drag). Only
        // when no file URL was present, so a dragged `.png` file is staged once
        // as a file (preserving its name), not double-staged as an image too.
        if !handled,
           let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !images.isEmpty {
            for image in images {
                onDropImage(image, nil)
                handled = true
            }
        }

        return handled
    }

    // MARK: Helpers

    /// True when the pasteboard carries at least one acceptable file URL or
    /// image type. Cheaper than `readObjects` so `draggingEntered` doesn't force
    /// promise resolution on every drag-move frame.
    private func pasteboardHasAcceptableItem(_ pasteboard: NSPasteboard) -> Bool {
        guard let type = pasteboard.availableType(from: Self.acceptableTypes) else { return false }
        // `.fileURL` / `.URL` / `.pdf` always indicate a real file; `.png` /
        // `.tiff` can be either a file URL or in-memory bytes, both acceptable.
        _ = type
        return true
    }
}
