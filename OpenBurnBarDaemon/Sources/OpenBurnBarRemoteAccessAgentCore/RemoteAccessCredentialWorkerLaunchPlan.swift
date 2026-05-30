import Foundation

public enum RemoteAccessCredentialWorkerLaunchPlan {
    public static let credentialWorkerArgument = "--type-credential-worker"

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

        if let loginWindowPID {
            return [
                "asuser",
                "\(consoleUserUID)",
                "/bin/launchctl",
                "bsexec",
                "\(loginWindowPID)",
            ] + workerArguments
        }

        return [
            "asuser",
            "\(consoleUserUID)",
        ] + workerArguments
    }
}
