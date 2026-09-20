import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import OSLog

public struct BugReportSheetView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var category: String = "Bug / Crash"
    @State private var includeDiagnostics: Bool = true
    @State private var autoDispenseCLI: Bool = true
    @State private var selectedRuntime: String = "claude"
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var successResult: BugReportSubmissionResult?

    private let categories = ["Bug / Crash", "UI Issue", "Agent / CLI Issue", "Sync / Quotas", "Other"]
    private let runtimes = [
        ("claude", "Claude Code"),
        ("codex", "Codex"),
        ("antigravity", "Antigravity"),
        ("droid", "Droid"),
        ("auto", "Auto")
    ]

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if let success = successResult {
                successView(success)
            } else {
                formView
            }
        }
        .frame(width: 540, height: 600)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 22))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Report an Issue or Feedback")
                    .font(.headline)
                Text("Files a ticket to Linear and dispenses a local CLI agent to investigate")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }

                // Category & Title
                VStack(alignment: .leading, spacing: 6) {
                    Text("Category")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.self) { cat in
                            Text(cat).tag(cat)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Brief title of what broke...", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                // Description
                VStack(alignment: .leading, spacing: 6) {
                    Text("Details & Steps to Reproduce")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $description)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 120)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }

                // Diagnostics Box
                Toggle(isOn: $includeDiagnostics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include System Diagnostics & Recent Logs")
                            .font(.subheadline)
                        Text("OS version, hardware specs, memory usage, and recent non-sensitive log traces.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                Divider()

                // CLI Agent Dispense Section
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $autoDispenseCLI) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Dispense CLI Agent on this Mac")
                                .font(.subheadline).bold()
                            Text("Immediately spawns an agent in Terminal to inspect the repo and reproduce/patch.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    if autoDispenseCLI {
                        HStack {
                            Text("Agent Runtime:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Picker("", selection: $selectedRuntime) {
                                ForEach(runtimes, id: \.0) { id, name in
                                    Text(name).tag(id)
                                }
                            }
                            .frame(width: 160)
                        }
                        .padding(.leading, 20)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(8)
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                Task { await submitReport() }
            } label: {
                HStack(spacing: 6) {
                    if isSubmitting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(autoDispenseCLI ? "Submit & Dispatch Agent" : "Submit to Linear")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func successView(_ success: BugReportSubmissionResult) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            VStack(spacing: 6) {
                Text("Bug Report Filed Successfully")
                    .font(.title2).bold()
                Text("Your issue is tracked on Linear and ready for resolution.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(success.linearIdentifier)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(6)

                    if let url = URL(string: success.linearUrl) {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Text("Open in Linear")
                                Image(systemName: "arrow.up.right.square")
                            }
                            .font(.caption)
                        }
                    }
                }

                if success.missionId != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .foregroundColor(.orange)
                        Text("CLI Agent mission dispatched to this Mac")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(10)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 20)
        }
        .padding(20)
    }

    private func submitReport() async {
        isSubmitting = true
        errorMessage = nil

        let diagnostics = includeDiagnostics ? SystemDiagnosticsCollector.capture().asDictionary : nil
        let submission = BugReportSubmission(
            title: "[\(category)] \(title.trimmingCharacters(in: .whitespacesAndNewlines))",
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : description,
            platform: "macOS",
            diagnostics: diagnostics,
            autoDispenseCLI: autoDispenseCLI,
            requestedRuntime: selectedRuntime
        )

        do {
            let result = try await BugReportService.submit(submission)
            successResult = result
        } catch {
            errorMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}
