import AppKit
import OpenBurnBarCore

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
        startupState = Self.makeStartupState()
        isRetryingStartup = false
        if startupState.runtimeContext != nil {
            hasPresentedStartupRecoveryWindow = false
            windowManager.closeStartupRecovery()
        } else {
            openStartupRecoveryWindow()
        }
    }

    @MainActor
    private func archiveAndResetStartupDatabase() {
        guard !isRetryingStartup && !isArchivingReset else { return }
        isArchivingReset = true
        startupRecoveryActionError = nil
        do {
            let archiveResult = try OpenBurnBarStartupRecovery.archiveDatabaseSidecars()
            startupState = Self.makeStartupState(archiveURL: archiveResult.archiveDirectory)
            isArchivingReset = false
            if startupState.runtimeContext != nil {
                hasPresentedStartupRecoveryWindow = false
                windowManager.closeStartupRecovery()
            } else {
                startupRecoveryActionError = "The database was archived, but OpenBurnBar still could not create a clean database."
                openStartupRecoveryWindow()
            }
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
