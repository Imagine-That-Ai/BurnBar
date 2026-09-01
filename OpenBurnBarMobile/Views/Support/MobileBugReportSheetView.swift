import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import OSLog

public struct MobileBugReportSheetView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var category: String = "Bug / Crash"
    @State private var includeDiagnostics: Bool = true
    @State private var autoDispenseCLI: Bool = true
    @State private var selectedRuntime: String = "claude"
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var successResult: MobileBugReportSubmissionResult?

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
        NavigationStack {
            if let success = successResult {
                successView(success)
            } else {
                formView
            }
        }
    }

    private var formView: some View {
        Form {
            if let error = errorMessage {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            Section("Issue Summary") {
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { cat in
                        Text(cat).tag(cat)
                    }
                }

                TextField("What went wrong?", text: $title)
            }

            Section("Details & Steps to Reproduce") {
                TextEditor(text: $description)
                    .frame(minHeight: 120)
            }

            Section {
                Toggle(isOn: $includeDiagnostics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include Device Diagnostics")
                            .font(.body)
                        Text("iOS version, device model, battery, thermal state.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Diagnostics")
            }

            Section {
                Toggle(isOn: $autoDispenseCLI) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Dispense Mac CLI Agent")
                            .font(.body).bold()
                        Text("Launches an agent on your Mac to investigate and fix.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if autoDispenseCLI {
                    Picker("Agent Runtime", selection: $selectedRuntime) {
                        ForEach(runtimes, id: \.0) { id, name in
                            Text(name).tag(id)
                        }
                    }
                }
            } header: {
                Text("Automation")
            }

            Section {
                Button {
                    Task { await submitReport() }
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text(autoDispenseCLI ? "Submit & Dispatch Mac Agent" : "Submit Bug Report")
                            .bold()
                        Spacer()
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            }
        }
        .navigationTitle("Report a Bug")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
    }

    private func successView(_ success: MobileBugReportSubmissionResult) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            VStack(spacing: 8) {
                Text("Bug Report Filed")
                    .font(.title2).bold()
                Text("Issue created on Linear and logged to your account.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Text(success.linearIdentifier)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(8)

                if let url = URL(string: success.linearUrl) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text("View on Linear")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.subheadline)
                    }
                }

                if success.missionId != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "laptopcomputer")
                            .foregroundColor(.orange)
                        Text("Mac CLI agent mission dispatched")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .padding()
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("Submitted")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submitReport() async {
        isSubmitting = true
        errorMessage = nil

        let diagnostics = includeDiagnostics ? MobileDiagnosticsCollector.capture().asDictionary : nil
        let submission = MobileBugReportSubmission(
            title: "[\(category)] \(title.trimmingCharacters(in: .whitespacesAndNewlines))",
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : description,
            platform: "iOS",
            diagnostics: diagnostics,
            autoDispenseCLI: autoDispenseCLI,
            requestedRuntime: selectedRuntime
        )

        do {
            let result = try await MobileBugReportService.submit(submission)
            successResult = result
        } catch {
            errorMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}
