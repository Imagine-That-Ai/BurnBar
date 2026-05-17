#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Mac approval sheet. 1pt `mercuryGradient` border, pre-action
/// screenshot thumbnail, action description + selector / coords, three
/// buttons (Reject + Halt, Reject, Approve). Phase 9. Plan § D.3.
public struct ComputerUseApprovalSheet: View {
    public struct Outcome: Equatable, Sendable {
        public enum Decision: String, Equatable, Sendable {
            case approve
            case reject
            case rejectAndHalt
        }
        public let decision: Decision
        public let approveBurst: Bool
    }

    let request: HermesRealtimeRelayApprovalRequest
    let beforeScreenshotPNG: Data?
    let liveTrustMode: ComputerUseTrustMode
    let onDecision: (Outcome) -> Void

    @State private var burstApproveSelected: Bool = false

    public init(
        request: HermesRealtimeRelayApprovalRequest,
        beforeScreenshotPNG: Data? = nil,
        liveTrustMode: ComputerUseTrustMode,
        onDecision: @escaping (Outcome) -> Void
    ) {
        self.request = request
        self.beforeScreenshotPNG = beforeScreenshotPNG
        self.liveTrustMode = liveTrustMode
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let png = beforeScreenshotPNG, let image = NSImage(data: png) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 320, height: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.secondary.opacity(0.4), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.08))
                    .frame(width: 320, height: 180)
                    .overlay(Text("Pre-action screenshot pending").font(.system(size: 11)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(request.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(request.actionSummary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Tool: \(request.toolKind) · session \(request.sessionId.prefix(8))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if liveTrustMode == .step {
                Toggle("Approve the next 10 similar actions automatically", isOn: $burstApproveSelected)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    onDecision(Outcome(decision: .rejectAndHalt, approveBurst: false))
                } label: {
                    Text("Reject + Halt").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(role: .cancel) {
                    onDecision(Outcome(decision: .reject, approveBurst: false))
                } label: {
                    Text("Reject").frame(maxWidth: .infinity)
                }

                Button {
                    onDecision(Outcome(decision: .approve, approveBurst: burstApproveSelected))
                } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .frame(maxWidth: 320)
        }
        .padding(20)
        .frame(width: 360)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(LinearGradient(
                    colors: [.orange.opacity(0.6), .red.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ), lineWidth: 1)
        )
    }
}
#endif
