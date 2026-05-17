#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct ComputerUseDeviceSheet: View {
    let phaseDescription: String
    let session: AgentWatchSessionSnapshot

    var body: some View {
        NavigationStack {
            List {
                Section("Mac connection") {
                    LabeledContent("Control stream", value: phaseDescription)
                    LabeledContent("Session", value: session.sessionId?.rawValue ?? "Not connected")
                    if let startedAt = session.startedAt {
                        LabeledContent("Started", value: startedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section("Safety") {
                    Label("Approvals are sent back over the signed control stream.", systemImage: "checkmark.shield")
                    Label("Panic halt sends a signed phone intent to the Mac.", systemImage: "exclamationmark.octagon")
                    Label("Trusted mode is visible and can be downgraded here.", systemImage: "hand.raised")
                }
            }
            .navigationTitle("Computer Use device")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
