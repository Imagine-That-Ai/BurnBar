#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Full-bleed iOS view that displays the Mac's mirrored surface and
/// overlays the planned-action chip, the pending-approval row, and the
/// trust-mode badge. Phase 8 ships the view; Phase 12 makes the
/// approval-row buttons functional via `PhoneControlSender`.
///
/// The frame layer in this stub is rendered by a child
/// `AgentWatchFrameView` (UIViewRepresentable wrapping
/// `AVSampleBufferDisplayLayer`); the implementation is sketched but
/// the full pipeline lives in the Mercury substrate already.
public struct AgentWatchView: View {
    @ObservedObject private var state: AgentWatchState
    private let downgradeTrustMode: (ComputerUseTrustMode) -> Void
    private let approveAction: (HermesRealtimeRelayApprovalRequest) -> Void
    private let rejectAction: (HermesRealtimeRelayApprovalRequest, Bool) -> Void
    private let panicHalt: () -> Void

    public init(
        state: AgentWatchState,
        downgradeTrustMode: @escaping (ComputerUseTrustMode) -> Void,
        approveAction: @escaping (HermesRealtimeRelayApprovalRequest) -> Void,
        rejectAction: @escaping (HermesRealtimeRelayApprovalRequest, Bool) -> Void,
        panicHalt: @escaping () -> Void
    ) {
        self._state = ObservedObject(wrappedValue: state)
        self.downgradeTrustMode = downgradeTrustMode
        self.approveAction = approveAction
        self.rejectAction = rejectAction
        self.panicHalt = panicHalt
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            framePlaceholder
            VStack {
                topHairline
                Spacer()
                bottomStrip
            }
        }
        .gesture(threeFingerPanicGesture)
    }

    private var framePlaceholder: some View {
        VStack {
            if state.currentCursor != nil {
                Image(systemName: "cursorarrow")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Image(systemName: "rectangle.dashed")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .foregroundStyle(.white.opacity(0.2))
            }
            Text("Awaiting Mac frame…")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var topHairline: some View {
        HStack(spacing: 12) {
            Text("Watching · \(state.liveTrustMode.rawValue.capitalized) · \(timeAgo)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Menu {
                Button("Step (Mac-side approval per action)") {
                    downgradeTrustMode(.step)
                }
                Button("Manual (approve on phone)") {
                    downgradeTrustMode(.manual)
                }
            } label: {
                Text(state.liveTrustMode.rawValue.capitalized + " ▼")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var bottomStrip: some View {
        VStack(spacing: 12) {
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.2), .white.opacity(0.0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
            HStack(spacing: 16) {
                Text(String(format: "Spent  $%.2f", state.dailySpentUSD))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Text("\(state.actionsExecuted) actions")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
            }
            if let next = state.actionTimeline.last {
                HStack {
                    Image(systemName: "wand.and.rays")
                    Text("Next: \(next.summary)")
                        .lineLimit(2)
                }
                .font(.system(size: 13))
                .foregroundStyle(.white)
            }
            if let pending = state.pendingApproval {
                HStack(spacing: 12) {
                    Button(action: { rejectAction(pending, true) }) {
                        Text("Reject + Halt")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button(action: { rejectAction(pending, false) }) {
                        Text("Reject")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: { approveAction(pending) }) {
                        Text("Approve")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    private var threeFingerPanicGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.8)
            .onEnded { _ in panicHalt() }
    }

    private var timeAgo: String {
        guard let started = state.sessionStartedAt else { return "—:—:—" }
        let elapsed = Int(Date().timeIntervalSince(started))
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%02d:%02d", m, s)
    }
}
#endif
