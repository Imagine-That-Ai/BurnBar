import ActivityKit
import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct AgentWatchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentWatchLiveActivityAttributes.self) { context in
            AgentWatchLockScreenView(context: context)
                .widgetURL(URL(string: "burnbar://agent-watch"))
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentWatchPulseDot(approvalPending: context.state.approvalPending)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.appName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.lastAction)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.actionsCount)")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AgentWatchActionButtons(approvalPending: context.state.approvalPending)
                }
            } compactLeading: {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                Text(context.state.appName.prefix(3).uppercased())
                    .font(.caption2.weight(.semibold))
            } minimal: {
                AgentWatchPulseDot(approvalPending: context.state.approvalPending)
            }
            .widgetURL(URL(string: "burnbar://agent-watch"))
        }
    }
}

private struct AgentWatchLockScreenView: View {
    let context: ActivityViewContext<AgentWatchLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentWatchPulseDot(approvalPending: context.state.approvalPending)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.appName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(context.state.lastAction)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(elapsedString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }

            AgentWatchActionButtons(approvalPending: context.state.approvalPending)
        }
        .padding(16)
    }

    private var elapsedString: String {
        let seconds = max(0, Int(context.state.elapsed))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }
}

private struct AgentWatchPulseDot: View {
    let approvalPending: Bool

    var body: some View {
        Circle()
            .fill(approvalPending ? Color.orange : Color.cyan)
            .frame(width: 12, height: 12)
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
            )
    }
}

private struct AgentWatchActionButtons: View {
    let approvalPending: Bool

    var body: some View {
        HStack(spacing: 8) {
            if #available(iOSApplicationExtension 17.0, *) {
                Button(intent: AgentApproveIntent()) {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .disabled(!approvalPending)
                Button(intent: AgentRejectIntent()) {
                    Label("Reject", systemImage: "xmark.circle")
                }
                .disabled(!approvalPending)
                Button(intent: AgentHaltIntent()) {
                    Label("Halt", systemImage: "stop.circle")
                }
                .tint(.red)
            } else {
                Text(approvalPending ? "Approval pending" : "Watching")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.weight(.semibold))
    }
}
