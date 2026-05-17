import ActivityKit
import WidgetKit
import SwiftUI
import OpenBurnBarCore

/// Live Activity for an active agent session.
///
/// Shows current cost ticker, elapsed time, and model in the Dynamic
/// Island and Lock Screen. Started by the daemon/macOS environment
/// when a session begins; ended when the session completes.
public struct InsightSessionLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var costUSD: Double
        public var elapsedSeconds: Int
        public var modelName: String
        public var providerName: String
        public var isComplete: Bool

        public init(costUSD: Double, elapsedSeconds: Int, modelName: String, providerName: String, isComplete: Bool = false) {
            self.costUSD = costUSD
            self.elapsedSeconds = elapsedSeconds
            self.modelName = modelName
            self.providerName = providerName
            self.isComplete = isComplete
        }
    }

    public var sessionID: String
    public var startTime: Date

    public init(sessionID: String, startTime: Date) {
        self.sessionID = sessionID
        self.startTime = startTime
    }
}

public struct InsightSessionLiveActivityView: View {
    let context: ActivityViewContext<InsightSessionLiveActivityAttributes>

    public var body: some View {
        ZStack {
            Color.black
            HStack(spacing: 12) {
                RingProgressView(
                    progress: min(1, context.state.costUSD / 5.0),
                    color: providerColor
                )
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("$\(String(format: "%.3f", context.state.costUSD))")
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("\(context.state.modelName) · \(elapsedString)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }

                Spacer(minLength: 0)

                if context.state.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(providerColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .activityBackgroundTint(Color.black)
        .activitySystemActionForegroundColor(providerColor)
    }

    private var providerColor: Color {
        switch context.state.providerName.lowercased() {
        case "anthropic": return .orange
        case "openai": return .green
        case "openrouter", "minimax", "z.ai", "kimi": return .purple
        default: return .cyan
        }
    }

    private var elapsedString: String {
        let s = context.state.elapsedSeconds
        let mins = s / 60
        let secs = s % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}

public struct InsightSessionLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: InsightSessionLiveActivityAttributes.self) { context in
            InsightSessionLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RingProgressView(
                        progress: min(1, context.state.costUSD / 5.0),
                        color: .cyan
                    )
                    .frame(width: 28, height: 28)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("$\(String(format: "%.2f", context.state.costUSD))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.modelName)
                        .font(.caption)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.state.providerName) · \(context.state.elapsedSeconds)s")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            } compactLeading: {
                Image(systemName: "cpu")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                Text("$\(String(format: "%.2f", context.state.costUSD))")
                    .font(.system(.caption2, design: .monospaced))
            } minimal: {
                Image(systemName: "cpu")
                    .foregroundStyle(.cyan)
            }
        }
    }
}
