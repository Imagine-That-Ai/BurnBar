import Foundation

public enum RemoteAccessCredentialWorkerLaunchPlan {
    public static let credentialWorkerArgument = "--type-credential-worker"
    public static let focusProbeWorkerArgument = "--focus-probe-worker"

    public static func launchctlArguments(
        executablePath: String,
        consoleUserUID: UInt32,
        loginWindowPID: Int32?,
        credentialFilePath: String
    ) -> [String] {
        let workerArguments = [
            executablePath,
            credentialWorkerArgument,
            "--credential-file",
            credentialFilePath
        ]

        return wrapForConsoleUser(
            workerArguments: workerArguments,
            consoleUserUID: consoleUserUID,
            loginWindowPID: loginWindowPID
        )
    }

    /// Diagnostic variant: launches the worker in `--focus-probe-worker` mode (no credential file),
    /// using the same console-user + loginwindow-bootstrap wrapper as the real credential worker so
    /// the probe exercises the identical event-delivery path.
    public static func focusProbeArguments(
        executablePath: String,
        consoleUserUID: UInt32,
        loginWindowPID: Int32?
    ) -> [String] {
        wrapForConsoleUser(
            workerArguments: [executablePath, focusProbeWorkerArgument],
            consoleUserUID: consoleUserUID,
            loginWindowPID: loginWindowPID
        )
    }

    private static func wrapForConsoleUser(
        workerArguments: [String],
        consoleUserUID: UInt32,
        loginWindowPID: Int32?
    ) -> [String] {
        if let loginWindowPID {
            return [
                "asuser",
                "\(consoleUserUID)",
                "/bin/launchctl",
                "bsexec",
                "\(loginWindowPID)"
            ] + workerArguments
        }

        return [
            "asuser",
            "\(consoleUserUID)"
        ] + workerArguments
    }
}
