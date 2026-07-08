import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

@MainActor
extension ChatSessionController {
    var activeDesktopControlGrant: AgentCapabilityGrant? {
        let runtimeID = assistantRuntimeID(for: chatBackend)
        if let grant = desktopControlGrant,
           grant.runtimeID == runtimeID,
           grant.threadID == activeThreadID,
           grant.isActive() {
            return grant
        }
        return AgentCapabilityGrantStore.shared.activeGrant(
            runtimeID: runtimeID,
            threadID: activeThreadID
        )
    }

    var desktopControlEnabled: Bool {
        activeDesktopControlGrant != nil
    }

    func grantDesktopControl(
        capabilities: Set<AgentDesktopCapability>,
        trustMode: ComputerUseTrustMode,
        duration: TimeInterval = 30 * 60
    ) {
        guard !capabilities.isEmpty else {
            revokeDesktopControl()
            return
        }
        desktopControlGrant = AgentCapabilityGrant.sessionGrant(
            runtimeID: assistantRuntimeID(for: chatBackend),
            threadID: activeThreadID,
            capabilities: capabilities,
            trustMode: trustMode,
            workspaceRootPath: chatWorkspaceURL.path,
            now: Date(),
            duration: duration
        )
        if let desktopControlGrant {
            AgentCapabilityGrantStore.shared.activate(desktopControlGrant)
        }
        desktopControlError = nil
    }

    func revokeDesktopControl() {
        AgentCapabilityGrantStore.shared.revoke(
            runtimeID: assistantRuntimeID(for: chatBackend),
            threadID: activeThreadID
        )
        desktopControlGrant = desktopControlGrant?.revoked()
        desktopControlError = nil
        Task { await cliBridge.cancelAndWait() }
    }

    func activeAgentToolBroker() -> AgentToolBroker? {
        guard let grant = activeDesktopControlGrant else { return nil }
        let grantReference = ChatSessionControllerGrantReference(self)
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        return AgentToolBroker(
            grant: grant,
            workspaceURL: chatWorkspaceURL,
            computerUseRuntimeController: computerUseRuntimeController,
            grantStillActive: { [grantReference, grantID = grant.grantID] in
                await grantReference.hasActiveGrant(id: grantID)
            },
            privilegedActionApprover: privilegedActionApprover
        )
        #else
        return AgentToolBroker(
            grant: grant,
            workspaceURL: chatWorkspaceURL,
            grantStillActive: { [grantReference, grantID = grant.grantID] in
                await grantReference.hasActiveGrant(id: grantID)
            },
            privilegedActionApprover: privilegedActionApprover
        )
        #endif
    }

    /// A1: surfaces a Mac-local approval before a privileged broker tool
    /// (shell / workspace write / desktop export) runs in a non-trusted grant.
    /// `nil` when no UI surface is available, which makes the broker fail closed
    /// (deny) rather than execute silently.
    var privilegedActionApprover: AgentToolBroker.PrivilegedActionApprover? {
        #if canImport(AppKit)
        return { _, summary in
            await MainActor.run { ChatSessionController.presentPrivilegedActionApproval(summary: summary) }
        }
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    @MainActor
    static func presentPrivilegedActionApproval(summary: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow this agent action?"
        alert.informativeText = summary
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    #endif
}
