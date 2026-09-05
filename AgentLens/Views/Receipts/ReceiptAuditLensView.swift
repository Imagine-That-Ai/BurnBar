import AppKit
import Foundation
import OpenBurnBarCore
import SwiftUI

// MARK: - Audit Lens View

struct ReceiptAuditLensView: View {
    let receipt: ReceiptRecord
    @State private var copiedSignature = false
    @Environment(\.colorScheme) private var colorScheme

    init(receipt: ReceiptRecord) {
        self.receipt = receipt
    }

    var body: some View {
        VStack(spacing: 16) {
            // Provenance Seal Header
            provenanceSealCard

            // Session & Project Metadata
            metadataCard

            // Git Version Control Trace
            if receipt.gitBranch != nil || receipt.gitCommit != nil {
                gitTraceCard
            }

            // Files Modified Section
            if !receipt.filesTouched.isEmpty {
                filesTouchedCard
            }

            // Tools Invocations Section
            if !receipt.toolsUsed.isEmpty {
                toolsUsedCard
            }
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audit and provenance proof for \(receipt.projectName), signature \(receipt.shortSignature)")
    }

    // MARK: - Subviews

    private var provenanceSealCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Cryptographic Ledger Proof")
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Text("SHA-256 Tamper-Proof Signature")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                Text(receipt.contentSignature)
                    .font(.system(size: 9.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(receipt.contentSignature, forType: .string)
                    copiedSignature = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copiedSignature = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copiedSignature ? "checkmark" : "doc.on.doc")
                        Text(copiedSignature ? "Copied" : "Copy")
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .clipShape(.rect(cornerRadius: 6))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(colorScheme == .dark ? 0.1 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var metadataCard: some View {
        VStack(spacing: 8) {
            auditRow(label: "Session ID", value: receipt.sessionId)
            auditRow(label: "Project", value: receipt.projectName)
            auditRow(label: "Provider", value: receipt.provider.displayName)
            auditRow(label: "Model", value: receipt.modelName)
            auditRow(label: "Timestamp", value: receipt.timestamp.formatted(date: .complete, time: .standard))
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var gitTraceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "point.topleft.down.to.point.bottomright.filled.curvepath")
                    .font(.caption)
                    .foregroundStyle(.purple)
                Text("Git Context")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            if let branch = receipt.gitBranch {
                auditRow(label: "Branch", value: branch)
            }
            if let commit = receipt.gitCommit {
                auditRow(label: "Commit", value: String(commit.prefix(8)))
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var filesTouchedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files Touched (\(receipt.filesTouched.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ForEach(receipt.filesTouched.prefix(5), id: \.self) { file in
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(file)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if receipt.filesTouched.count > 5 {
                Text("+ \(receipt.filesTouched.count - 5) more files")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var toolsUsedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tools / Commands (\(receipt.toolsUsed.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            FlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(receipt.toolsUsed, id: \.self) { tool in
                    Text(tool)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(.rect(cornerRadius: 4))
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func auditRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
