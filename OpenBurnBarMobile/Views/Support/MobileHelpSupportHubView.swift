import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct MobileHelpSupportHubView: View {
    @State private var showingBugReport = false
    @State private var diagnosticsSnapshot: MobileDiagnosticsCollector.Snapshot?

    public init() {}

    public var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.blue)
                        Text("Help & Support")
                            .font(.title3).bold()
                    }
                    Text("Device status, troubleshooting utilities, and automated bug reporting.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Report an Issue") {
                Button {
                    showingBugReport = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "ladybug.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Report a Bug")
                                .font(.body).bold()
                                .foregroundColor(.primary)
                            Text("Creates a Linear issue & dispatches a Mac CLI agent")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let snap = diagnosticsSnapshot {
                Section("Device Health & Diagnostics") {
                    LabeledContent("iOS Version", value: snap.osVersion)
                    LabeledContent("Device Model", value: snap.deviceModel)
                    LabeledContent("App Version", value: "\(snap.appVersion) (\(snap.appBuild))")
                    LabeledContent("Thermal State", value: snap.thermalState)
                }
            }

            Section("Troubleshooting") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac CLI Agent Not Responding?")
                        .font(.subheadline).bold()
                    Text("Ensure your Mac is running OpenBurnBar with CLI assistant permissions enabled in Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Quota Sync Stale?")
                        .font(.subheadline).bold()
                    Text("Pull to refresh on the Providers tab or re-check your connected API keys.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Help & Support")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            diagnosticsSnapshot = MobileDiagnosticsCollector.capture()
        }
        .sheet(isPresented: $showingBugReport) {
            MobileBugReportSheetView()
        }
    }
}
