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

    /// Imports a file URL into the active chat workspace.
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

    /// Imports an in-memory image into the workspace.
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
