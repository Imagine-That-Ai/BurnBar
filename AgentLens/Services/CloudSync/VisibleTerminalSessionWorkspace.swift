import Foundation

/**
 * Encapsulates the filesystem side of a visible Terminal.app CLI session.
 *
 * Security requirements:
 *   - Session directory is created with 0o700 so only the owning user can list it.
 *   - Transcript log is pre-created with 0o600 before `tee` inherits it.
 *   - Cleanup removes the whole per-session directory on exit.
 *
 * Extracted into a separate value type so the permission/cleanup invariant is
 * unit-testable without spawning Terminal.app in CI.
 */
struct VisibleTerminalSessionWorkspace {
    let rootURL: URL
    let sessionURL: URL
    let logURL: URL
    let scriptURL: URL
    let exitURL: URL
    let pidURL: URL

    private init(rootURL: URL, sessionID: String) {
        self.rootURL = rootURL
        self.sessionURL = rootURL.appendingPathComponent(sessionID, isDirectory: true)
        self.logURL = sessionURL.appendingPathComponent("terminal.log")
        self.scriptURL = sessionURL.appendingPathComponent("run.command")
        self.exitURL = sessionURL.appendingPathComponent("exit.status")
        self.pidURL = sessionURL.appendingPathComponent("terminal.pid")
    }

    /**
     * Create the session directory and its restricted transcript log.
     *
     * - Parameters:
     *   - sessionID: opaque identifier for this terminal session.
     *   - fileManager: filesystem abstraction; injected in tests.
     * - Throws: any error from `createDirectory` or `createFile`.
     */
    enum PreparationError: Error, Equatable {
        case emptySessionID
        case logFileCreationFailed(URL)
    }

    static func prepare(
        sessionID: String,
        fileManager: FileManager = .default
    ) throws -> VisibleTerminalSessionWorkspace {
        guard !sessionID.isEmpty else {
            throw PreparationError.emptySessionID
        }

        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("OpenBurnBarVisibleCLI", isDirectory: true)
        let workspace = VisibleTerminalSessionWorkspace(rootURL: rootURL, sessionID: sessionID)

        try fileManager.createDirectory(
            at: workspace.sessionURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Pre-create log file with strict 0o600 permissions so tee inherits it.
        let created = fileManager.createFile(
            atPath: workspace.logURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw PreparationError.logFileCreationFailed(workspace.logURL)
        }

        return workspace
    }

    /**
     * Remove the session directory, logging any failure without throwing.
     */
    func cleanup(fileManager: FileManager = .default) {
        if fileManager.fileExists(atPath: sessionURL.path) {
            do {
                try fileManager.removeItem(at: sessionURL)
            } catch {
                AppLogger.sync.error(
                    "mission_visible_terminal_cleanup_failed",
                    metadata: [
                        "sessionURL": sessionURL.path,
                        "errorClass": "\(String(describing: type(of: error)))"
                    ]
                )
            }
        }
    }
}
