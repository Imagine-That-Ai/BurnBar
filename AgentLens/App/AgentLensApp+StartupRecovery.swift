import AppKit
import OpenBurnBarKernel

// Extracted verbatim from AgentLensApp.swift (audit wave 4, item 14).
// Data-store startup-failure recovery: the recovery window plus its
// retry / archive-and-reset / reveal / copy-diagnostics / quit actions.
extension OpenBurnBarApp {
    @MainActor
    func openStartupRecoveryWindow() {
        guard let failure = startupState.failure else { return }
        windowManager.openStartupRecovery(
            failure: failure,
            isRetrying: isRetryingStartup,
            isArchivingReset: isArchivingReset,
            actionError: startupRecoveryActionError,
            onRetry: retryStartup,
            onRevealSupportFolder: revealStartupSupportFolder,
            onArchiveAndReset: archiveAndResetStartupDatabase,
            onCopyDiagnostics: copyStartupDiagnostics,
            onQuit: quitFromStartupRecovery
        )
    }

    @MainActor
    private func retryStartup() {
        guard !isRetryingStartup && !isArchivingReset else { return }
        isRetryingStartup = true
        startupRecoveryActionError = nil
        openStartupRecoveryWindow()
        Task { @MainActor in
            startupState = await Self.makeStartupState()
            isRetryingStartup = false
            await finishStartup(isRecoveryAttempt: true)
        }
    }

    @MainActor
    private func archiveAndResetStartupDatabase() {
        guard !isRetryingStartup && !isArchivingReset else { return }
        isArchivingReset = true
        startupRecoveryActionError = nil
        openStartupRecoveryWindow()
        Task { @MainActor in
            do {
                let archiveResult = try await Task.detached(priority: .userInitiated) {
                    try OpenBurnBarStartupRecovery.archiveDatabaseSidecars()
                }.value
                startupState = await Self.makeStartupState(archiveURL: archiveResult.archiveDirectory)
                isArchivingReset = false
                if startupState.runtimeContext == nil {
                    startupRecoveryActionError = "The database was archived, but OpenBurnBar still could not create a clean database."
                }
                await finishStartup(isRecoveryAttempt: true)
            } catch {
                isArchivingReset = false
                startupRecoveryActionError = error.localizedDescription
                AppLogger.dataStore.error(
                    "startup_datastore_archive_reset_failed",
                    metadata: ["error": String(describing: error)]
                )
                openStartupRecoveryWindow()
            }
        }
    }

    @MainActor
    func finishStartup(isRecoveryAttempt: Bool = false) async {
        installCommandRouter()
        await Task.yield()
        if let context = startupState.runtimeContext {
            guard context.aggregator != nil else { return }
            hasPresentedStartupRecoveryWindow = false
            windowManager.closeStartupRecovery()
            let action = pendingStartupAction
            pendingStartupAction = nil
            action?()
        } else if isRecoveryAttempt {
            openStartupRecoveryWindow()
        } else {
            presentStartupRecoveryIfNeeded()
        }
    }

    @MainActor
    private func revealStartupSupportFolder() {
        guard let failure = startupState.failure else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: failure.supportDirectory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([failure.supportDirectory])
        } else {
            NSWorkspace.shared.selectFile(
                nil,
                inFileViewerRootedAtPath: failure.supportDirectory.deletingLastPathComponent().path
            )
        }
    }

    @MainActor
    private func copyStartupDiagnostics() -> Bool {
        guard let failure = startupState.failure else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(failure.diagnostics, forType: .string)
    }

    @MainActor
    private func quitFromStartupRecovery() {
        NSApplication.shared.terminate(nil)
    }
}
