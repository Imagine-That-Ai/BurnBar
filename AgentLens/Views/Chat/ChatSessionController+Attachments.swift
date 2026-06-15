import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

// Attachment handling.
// Extracted from ChatSessionController.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ChatSessionController {

    func looksLikeCredentialExposureQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let exposureVerbs = [
            "drop", "dropped", "paste", "pasted", "enter", "entered", "enterd",
            "share", "shared", "expose", "exposed", "leak", "leaked",
            "send", "sent", "type", "typed", "put", "posted"
        ]
        return SearchService.looksLikeSensitiveExactLookup(text)
            && exposureVerbs.contains { lower.contains($0) }
    }

    /// Imports a file URL (NSOpenPanel pick, drag-and-drop) into the
    /// active chat workspace and stages it on the next outgoing message.
    func addAttachment(from url: URL) {
        ensureChatWorkspaceDirectoryExists()
        do {
            let attachment = try HermesAttachmentLoader.importFile(at: url, intoWorkspace: chatWorkspaceURL)
            pendingAttachments.append(attachment)
            attachmentError = nil
        } catch {
            attachmentError = error.localizedDescription
            AppLogger.chat.silentFailure("addAttachment", error: error)
        }
    }

    /// Imports an in-memory image (clipboard paste, dragged NSImage) into
    /// the workspace.
    func addAttachment(image: NSImage, suggestedName: String? = nil) {
        ensureChatWorkspaceDirectoryExists()
        do {
            let attachment = try HermesAttachmentLoader.importImage(
                image,
                suggestedName: suggestedName,
                intoWorkspace: chatWorkspaceURL
            )
            pendingAttachments.append(attachment)
            attachmentError = nil
        } catch {
            attachmentError = error.localizedDescription
            AppLogger.chat.silentFailure("addAttachment(image)", error: error)
        }
    }

    func removeAttachment(_ id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Aggregate token-cost estimate for the currently staged attachments.
    var pendingAttachmentTokenEstimate: Int {
        pendingAttachments.reduce(0) { $0 + $1.estimatedTokenCost }
    }
}
