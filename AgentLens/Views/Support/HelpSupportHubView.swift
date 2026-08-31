import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public struct HelpSupportHubView: View {
    @State private var showingBugReportSheet = false
    @State private var diagnosticsSnapshot: SystemDiagnosticsCollector.Snapshot?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection

                systemHealthSection

                actionsSection

                troubleshootingSection
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 520)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            diagnosticsSnapshot = SystemDiagnosticsCollector.capture()
        }
        .sheet(isPresented: $showingBugReportSheet) {
            BugReportSheetView()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.blue)
                Text("Help & Support")
                    .font(.title2).bold()
            }
            Text("System health, diagnostic utilities, and automated bug reporting.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var systemHealthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Health & Diagnostics")
                .font(.headline)

            if let snap = diagnosticsSnapshot {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    healthMetricCard(title: "macOS Version", value: snap.osVersion, icon: "apple.logo")
                    healthMetricCard(title: "App Version", value: "\(snap.appVersion) (\(snap.appBuild))", icon: "app.badge")
                    healthMetricCard(title: "Memory Usage", value: "\(snap.memoryUsageMB) MB / \(snap.physicalMemoryGB) GB", icon: "memorychip")
                    healthMetricCard(title: "Daemon Status", value: snap.isDaemonConnected ? "Active & Healthy" : "Offline", icon: "bolt.horizontal.circle.fill", isGood: snap.isDaemonConnected)
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report an Issue")
                .font(.headline)

            HStack(spacing: 16) {
                Button {
                    showingBugReportSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "ladybug.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Submit Bug Report")
                                .font(.headline)
                            Text("Sends report to Linear & auto-dispenses CLI agent on Mac")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var troubleshootingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Troubleshooting")
                .font(.headline)

            VStack(spacing: 8) {
                troubleshootingRow(
                    title: "Daemon Unreachable",
                    description: "Check if openburnbar-daemon is running or restart via Status Item -> Settings."
                )
                troubleshootingRow(
                    title: "Quota Snapshot Stale",
                    description: "Open Provider Accounts to trigger a live sync or re-authenticate your API key."
                )
                troubleshootingRow(
                    title: "Terminal CLI Launch",
                    description: "Ensure your CLI agent (claude, codex, agy, or droid) is installed in your PATH."
                )
            }
        }
    }

    private func healthMetricCard(title: String, value: String, icon: String, isGood: Bool = true) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(isGood ? .blue : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func troubleshootingRow(title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline).bold()
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(6)
    }
}
