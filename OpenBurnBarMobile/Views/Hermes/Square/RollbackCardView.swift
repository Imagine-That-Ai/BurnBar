import SwiftUI
import OpenBurnBarCore

// MARK: - Rollback Card View (Hermes Square §6.10)
//
// Inline rollback affordance the Living Inbox / mission tile renders to
// surface the per-session DiffBack-style snapshots. Three quick actions:
//   • Roll back the whole session
//   • Roll back the most recent action
//   • Open a per-file picker

struct RollbackCardView: View {
    let sessionID: String
    let snapshots: [RollbackSnapshot]
    let onSubmit: (RollbackScope) -> Void

    @State private var isFilePickerPresented: Bool = false

    private var newestSnapshot: RollbackSnapshot? {
        snapshots.sorted { $0.sequence > $1.sequence }.first
    }

    private var touchedFiles: [String] {
        Array(Set(snapshots.flatMap(\.touchedFiles))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(DesignSystemColors.whimsy)
                Text("Rollback")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
                Spacer()
                Text("\(snapshots.count) snapshots")
                    .font(.caption2)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
            if snapshots.isEmpty {
                Text("No snapshots yet — the Mac writes them as the agent acts.")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            } else {
                HStack(spacing: 6) {
                    actionButton(label: "Whole session", systemImage: "tray.and.arrow.up") {
                        onSubmit(.fullSession)
                    }
                    actionButton(label: "Last action", systemImage: "arrow.uturn.backward") {
                        onSubmit(.lastN(count: 1))
                    }
                    actionButton(label: "Per-file…", systemImage: "doc.on.doc") {
                        isFilePickerPresented = true
                    }
                }
                if let newest = newestSnapshot {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(DesignSystemColors.whimsy)
                        Text("Latest: \(newest.actionLabel) • \(MissionConsoleFormatting.relativeTime(newest.takenAt))")
                            .font(.caption2)
                            .foregroundStyle(DesignSystemColors.textMuted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignSystemColors.whimsy.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(DesignSystemColors.whimsy.opacity(0.3), lineWidth: 0.5)
                )
        )
        .sheet(isPresented: $isFilePickerPresented) {
            RollbackFilePickerSheet(
                touchedFiles: touchedFiles,
                onPick: { path in
                    onSubmit(.singleFile(path: path))
                    isFilePickerPresented = false
                }
            )
        }
    }

    private func actionButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.callout)
                Text(label)
                    .font(.caption2.bold())
                    .lineLimit(1)
            }
            .foregroundStyle(DesignSystemColors.whimsy)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignSystemColors.whimsy.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct RollbackFilePickerSheet: View {
    let touchedFiles: [String]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if touchedFiles.isEmpty {
                    Text("No files in any snapshot yet.")
                        .foregroundStyle(DesignSystemColors.textMuted)
                } else {
                    ForEach(touchedFiles, id: \.self) { path in
                        Button {
                            onPick(path)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(DesignSystemColors.whimsy)
                                Text(path)
                                    .font(.callout.monospaced())
                                Spacer()
                                Image(systemName: "arrow.uturn.backward")
                                    .foregroundStyle(DesignSystemColors.whimsy)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Pick a file to revert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
