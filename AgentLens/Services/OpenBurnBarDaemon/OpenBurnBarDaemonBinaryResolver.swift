import Foundation

enum OpenBurnBarDaemonProcessRunner {
    static func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw OpenBurnBarDaemonManagerError.launchctlFailed(error.isEmpty ? output : error)
        }

        return output
    }
}

enum OpenBurnBarDaemonBinaryResolver {
    static func resolve(appBundleURL: URL, fileManager: FileManager) -> URL? {
        let candidates = [
            appBundleURL.appendingPathComponent("Contents/Helpers/OpenBurnBarDaemon", isDirectory: false),
            appBundleURL.deletingLastPathComponent().appendingPathComponent("OpenBurnBarDaemon", isDirectory: false),
            appBundleURL.deletingLastPathComponent().appendingPathComponent("BurnBarDaemonExecutable", isDirectory: false)
        ]

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Locates the OpenBurnBarCore resource bundle that must be installed alongside the daemon binary.
    static func resolveResourceBundle(
        nearBinaryURL: URL,
        appBundleURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let binaryDirectory = nearBinaryURL.deletingLastPathComponent()
        let appParent = appBundleURL.deletingLastPathComponent()
        let bundleNames = [
            OpenBurnBarDaemonManager.resourceBundleName,
            OpenBurnBarDaemonManager.legacyResourceBundleNames[0],
        ]
        let candidates = bundleNames.flatMap { bundleName in
            [
                binaryDirectory.appendingPathComponent(bundleName),
                binaryDirectory.appendingPathComponent("Resources").appendingPathComponent(bundleName),
                appBundleURL.appendingPathComponent("Contents/Resources/\(bundleName)"),
                appBundleURL.appendingPathComponent("Contents/Frameworks/\(bundleName)"),
                appParent.appendingPathComponent(bundleName),
                appParent.appendingPathComponent("PackageFrameworks").appendingPathComponent(bundleName),
            ]
        }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}
