#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarComputerUseCore
// `HermesAttachment` only. Kernel rather than the OpenBurnBarCore umbrella
// because the umbrella is ratchet-only for OpenBurnBarMobile — and it is
// provably the same type: OpenBurnBarCore @_exported imports Kernel, which
// @_exported imports OpenBurnBarAssistantModels, where HermesAttachment lives.
// (OpenBurnBarData declares a second, distinct HermesAttachment; importing
// that one instead would silently substitute a different type.)
import OpenBurnBarKernel

/// Agent Control surface: live puck + permission sheet. Not a CLI thread view.
struct AgentControlComposer: View {
    @ObservedObject var presenter: AgentLiveStagePresenter
    @Bindable var hermesService: HermesService
    var attachments: [HermesAttachment] = []
    var missionAttachments: [CLIAgentMissionAttachmentRef] = []
    var threadID: String = "agent-control"
    var onInterrupt: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            AgentLiveStageChatPuck(presenter: presenter, hermesService: hermesService)
            if !attachments.isEmpty || !missionAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachments) { item in
                            Text(item.displayName)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule())
                        }
                        ForEach(missionAttachments) { item in
                            Text(item.displayName)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                }
                .accessibilityIdentifier("agentControlAttachmentChips")
            }
            AgentPermissionGrantSheet(runtimeID: .hermes, threadID: threadID)
            Button("Interrupt session", action: onInterrupt)
                .accessibilityIdentifier("agentControlInterrupt")
        }
    }
}
#endif
