import SwiftUI

enum DataStoreStartupRecoveryCopyStatus {
    case copied
    case failed

    var isSuccess: Bool {
        self == .copied
    }

    var systemImage: String {
        isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    var message: String {
        switch self {
        case .copied:
            return "Diagnostics copied to the clipboard."
        case .failed:
            return "Diagnostics could not be copied. Use Show Support Folder instead."
        }
    }

    var panelColor: Color {
        isSuccess ? DesignSystem.Colors.success.opacity(0.08) : DesignSystem.Colors.error.opacity(0.08)
    }
}

struct DataStoreStartupRecoveryView: View {
    let failure: DataStoreStartupFailure
    var isRetrying = false
    var isArchivingReset = false
    var actionError: String?
    var compact = false
    let onRetry: () -> Void
    let onRevealSupportFolder: () -> Void
    let onArchiveAndReset: () -> Void
    let onCopyDiagnostics: () -> Bool
    let onQuit: () -> Void

    @State private var isConfirmingReset = false
    @State private var copyStatus: DataStoreStartupRecoveryCopyStatus?

    init(
        failure: DataStoreStartupFailure,
        isRetrying: Bool = false,
        isArchivingReset: Bool = false,
        actionError: String? = nil,
        compact: Bool = false,
        initialCopyStatus: DataStoreStartupRecoveryCopyStatus? = nil,
        onRetry: @escaping () -> Void,
        onRevealSupportFolder: @escaping () -> Void,
        onArchiveAndReset: @escaping () -> Void,
        onCopyDiagnostics: @escaping () -> Bool,
        onQuit: @escaping () -> Void
    ) {
        self.failure = failure
        self.isRetrying = isRetrying
        self.isArchivingReset = isArchivingReset
        self.actionError = actionError
        self.compact = compact
        self.onRetry = onRetry
        self.onRevealSupportFolder = onRevealSupportFolder
        self.onArchiveAndReset = onArchiveAndReset
        self.onCopyDiagnostics = onCopyDiagnostics
        self.onQuit = onQuit
        _copyStatus = State(initialValue: initialCopyStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? DesignSystem.Spacing.md : DesignSystem.Spacing.lg) {
            header
            explanation
            diagnosticPanel
            if let actionError {
                errorPanel(actionError)
            }
            if let copyStatus {
                feedbackPanel(copyStatus)
            }
            actionRows
        }
        .padding(compact ? DesignSystem.Spacing.lg : DesignSystem.Spacing.xl)
        .frame(width: compact ? 360 : 520)
        .background(DesignSystem.Colors.background)
        .confirmationDialog(
            "Archive and reset the local database?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Archive and Reset Database", role: .destructive) {
                onArchiveAndReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OpenBurnBar will copy the current database files into StartupRecovery before creating a clean database.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: compact ? 24 : 30, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.error)
                .frame(width: compact ? 28 : 36)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Database needs attention")
                    .font(compact ? DesignSystem.Typography.headline : DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("OpenBurnBar started in recovery mode.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }

    private var explanation: some View {
        Text("The local database could not be opened. This can happen when disk space is exhausted, file permissions change, or SQLite detects a damaged migration state. Background sync and parsing are paused until storage is healthy again.")
            .font(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var diagnosticPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            diagnosticRow(label: "Error", value: failure.errorSummary)
            diagnosticRow(label: "Database", value: failure.databaseURL.path)
            if let archiveURL = failure.archiveURL {
                diagnosticRow(label: "Archive", value: archiveURL.path)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        }
    }

    private func diagnosticRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(compact ? 3 : 4)
                .textSelection(.enabled)
        }
    }

    private func errorPanel(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.error)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
    }

    private func feedbackPanel(_ status: DataStoreStartupRecoveryCopyStatus) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.isSuccess ? DesignSystem.Colors.success : DesignSystem.Colors.error)
            Text(status.message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.md)
        .background(status.panelColor)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
    }

    private var actionRows: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    retryButton
                    archiveButton
                    revealSupportFolderButton
                    copyDiagnosticsButton
                    quitButton
                }
            } else {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        retryButton
                        archiveButton
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        revealSupportFolderButton
                        copyDiagnosticsButton
                        quitButton
                    }
                }
            }
        }
    }

    private var retryButton: some View {
        recoveryButton(
            title: isRetrying ? "Retrying" : "Retry",
            systemImage: "arrow.clockwise",
            isProminent: true,
            isDisabled: isRetrying || isArchivingReset,
            action: {
                copyStatus = nil
                onRetry()
            }
        )
    }

    private var archiveButton: some View {
        recoveryButton(
            title: isArchivingReset ? "Archiving" : "Archive and Reset",
            systemImage: "archivebox",
            isDestructive: true,
            isDisabled: isRetrying || isArchivingReset,
            action: {
                copyStatus = nil
                isConfirmingReset = true
            }
        )
    }

    private var revealSupportFolderButton: some View {
        recoveryButton(
            title: "Show Support Folder",
            systemImage: "folder",
            action: onRevealSupportFolder
        )
    }

    private var copyDiagnosticsButton: some View {
        recoveryButton(
            title: "Copy Diagnostics",
            systemImage: "doc.on.doc",
            action: {
                copyStatus = onCopyDiagnostics() ? .copied : .failed
            }
        )
    }

    private var quitButton: some View {
        recoveryButton(
            title: "Quit",
            systemImage: "power",
            action: onQuit
        )
    }

    private func recoveryButton(
        title: String,
        systemImage: String,
        isProminent: Bool = false,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
            }
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(buttonForeground(isProminent: isProminent, isDestructive: isDestructive))
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(buttonBackground(isProminent: isProminent, isDestructive: isDestructive))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: isProminent || isDestructive ? 0 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }

    private func buttonForeground(isProminent: Bool, isDestructive: Bool) -> Color {
        if isProminent || isDestructive { return Color.white }
        return DesignSystem.Colors.textPrimary
    }

    private func buttonBackground(isProminent: Bool, isDestructive: Bool) -> Color {
        if isDestructive { return DesignSystem.Colors.error }
        if isProminent { return DesignSystem.Colors.blaze }
        return DesignSystem.Colors.surfaceElevated
    }

}
