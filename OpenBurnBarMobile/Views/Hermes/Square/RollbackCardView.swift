import SwiftUI
import OpenBurnBarCore

// MARK: - Rollback Card View (Hermes Square §6.10)
//
// Inline rollback affordance the Living Inbox / mission tile renders to
// surface the per-session DiffBack-style snapshots. Three quick actions:
//   • Roll back the whole session
//   • Roll back the most recent action
//   • Open a per-file picker
//
// Motion: after a rollback completes (a snapshot transitions to
// `restoredAt != nil`), an animated success checkmark overlays the card
// for ~1.6s — Path.trim draws the tick stroke from 0→1, then a halo
// ring blooms and fades. Editorial, not celebratory.

struct RollbackCardView: View {
    let sessionID: String
    let snapshots: [RollbackSnapshot]
    let onSubmit: (RollbackScope) -> Void

    @State private var isFilePickerPresented: Bool = false
    @State private var successPing: Int = 0
    @State private var lastSeenRestoredAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var newestSnapshot: RollbackSnapshot? {
        snapshots.sorted { $0.sequence > $1.sequence }.first
    }

    private var touchedFiles: [String] {
        Array(Set(snapshots.flatMap(\.touchedFiles))).sorted()
    }

    /// Most-recent restoredAt across all snapshots. Drives the success
    /// checkmark trigger: when this advances forward, we ping the
    /// overlay. Computed (not stored) so re-renders pick it up cheaply.
    private var latestRestoredAt: Date? {
        snapshots.compactMap(\.restoredAt).max()
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
        .overlay(
            RollbackSuccessOverlay(trigger: successPing)
                .allowsHitTesting(false)
        )
        .onAppear {
            lastSeenRestoredAt = latestRestoredAt
        }
        .onChange(of: latestRestoredAt) { _, newValue in
            // Bump the trigger only on a forward transition — first
            // restore for this card, OR a new restore replacing an older
            // one. Ignores the initial `nil → some` on mount.
            guard !reduceMotion, let newValue else { return }
            if let prior = lastSeenRestoredAt, newValue <= prior { return }
            lastSeenRestoredAt = newValue
            successPing &+= 1
        }
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

// MARK: - Success overlay (checkmark draw-in + halo)

private struct RollbackSuccessOverlay: View {
    let trigger: Int

    enum Phase: CaseIterable {
        case idle, drawingTick, holdingTick, bloom, fade

        var tickProgress: CGFloat {
            switch self {
            case .idle:         return 0.0
            case .drawingTick:  return 1.0
            case .holdingTick:  return 1.0
            case .bloom:        return 1.0
            case .fade:         return 1.0
            }
        }

        var tickOpacity: Double {
            switch self {
            case .idle:         return 0.0
            case .drawingTick:  return 1.0
            case .holdingTick:  return 1.0
            case .bloom:        return 1.0
            case .fade:         return 0.0
            }
        }

        var haloScale: CGFloat {
            switch self {
            case .idle:         return 0.4
            case .drawingTick:  return 0.55
            case .holdingTick:  return 0.7
            case .bloom:        return 1.3
            case .fade:         return 1.55
            }
        }

        var haloOpacity: Double {
            switch self {
            case .idle:         return 0.0
            case .drawingTick:  return 0.35
            case .holdingTick:  return 0.55
            case .bloom:        return 0.30
            case .fade:         return 0.0
            }
        }
    }

    var body: some View {
        ZStack {
            // Slow render-driver: a phase animator that runs once per
            // trigger bump through the five phases and rests in `.idle`.
            EmptyView()
                .phaseAnimator(Phase.allCases, trigger: trigger) { _, phase in
                    successContent(phase: phase)
                } animation: { phase in
                    switch phase {
                    case .idle:         return .linear(duration: 0)
                    case .drawingTick:  return .easeOut(duration: 0.32)
                    case .holdingTick:  return .linear(duration: 0.25)
                    case .bloom:        return .easeOut(duration: 0.40)
                    case .fade:         return .easeIn(duration: 0.45)
                    }
                }
        }
    }

    @ViewBuilder
    private func successContent(phase: Phase) -> some View {
        ZStack {
            Circle()
                .stroke(DesignSystemColors.success.opacity(phase.haloOpacity), lineWidth: 1.5)
                .frame(width: 64, height: 64)
                .scaleEffect(phase.haloScale)
            Circle()
                .fill(DesignSystemColors.success.opacity(min(phase.haloOpacity * 0.55, 0.35)))
                .frame(width: 44, height: 44)
            CheckmarkShape()
                .trim(from: 0, to: phase.tickProgress)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 22, height: 16)
                .opacity(phase.tickOpacity)
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.04, y: h * 0.55))
        path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.92))
        path.addLine(to: CGPoint(x: w * 0.98, y: h * 0.12))
        return path
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
