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

    /// Locates framework bundles that must be copied into the daemon install tree.
    ///
    /// Release builds install `OpenBurnBarDaemon` under Application Support at:
    /// `.../OpenBurnBar/daemon/OpenBurnBarDaemon`. The helper's hardened-runtime
    /// rpath is `@executable_path/../Frameworks`, so frameworks embedded in the
    /// `.app` bundle must also be mirrored to `.../OpenBurnBar/Frameworks`.
    static func resolveRuntimeFrameworks(
        nearBinaryURL: URL,
        appBundleURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        let binaryDirectory = nearBinaryURL.deletingLastPathComponent()
        let binaryParent = binaryDirectory.deletingLastPathComponent()
        let appParent = appBundleURL.deletingLastPathComponent()
        let frameworkDirectories = [
            binaryParent.appendingPathComponent("Frameworks", isDirectory: true),
            appBundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true),
            binaryDirectory.appendingPathComponent("Frameworks", isDirectory: true),
            appParent.appendingPathComponent("PackageFrameworks", isDirectory: true)
        ]

        var seen = Set<URL>()
        var frameworks: [URL] = []
        for directory in frameworkDirectories {
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children where child.pathExtension == "framework" {
                let standardized = child.standardizedFileURL
                guard !seen.contains(standardized) else { continue }
                seen.insert(standardized)
                frameworks.append(child)
            }
        }
        return frameworks
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
            OpenBurnBarDaemonManager.legacyResourceBundleNames[0]
        ]
        let candidates = bundleNames.flatMap { bundleName in
            [
                binaryDirectory.appendingPathComponent(bundleName),
                binaryDirectory.appendingPathComponent("Resources").appendingPathComponent(bundleName),
                appBundleURL.appendingPathComponent("Contents/Resources/\(bundleName)"),
                appBundleURL.appendingPathComponent("Contents/Frameworks/\(bundleName)"),
                appParent.appendingPathComponent(bundleName),
                appParent.appendingPathComponent("PackageFrameworks").appendingPathComponent(bundleName)
            ]
        }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    static func resolveProjectCodeMemorySecretCorpus(
        nearBinaryURL: URL,
        appBundleURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let binaryDirectory = nearBinaryURL.deletingLastPathComponent()
        let appParent = appBundleURL.deletingLastPathComponent()
        let resourceDirectoryName = OpenBurnBarDaemonManager.projectCodeMemoryResourceDirectoryName
        let fileName = OpenBurnBarDaemonManager.projectCodeMemorySecretCorpusFileName

        let bases = [
            binaryDirectory,
            binaryDirectory.appendingPathComponent("Resources", isDirectory: true),
            appBundleURL.appendingPathComponent("Contents/Resources", isDirectory: true),
            appParent,
            appParent.appendingPathComponent("Resources", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent()
        ]

        var candidates: [URL] = []
        for base in bases {
            var cursor = base.standardizedFileURL
            for _ in 0..<8 {
                candidates.append(cursor.appendingPathComponent(fileName, isDirectory: false))
                candidates.append(
                    cursor
                        .appendingPathComponent(resourceDirectoryName, isDirectory: true)
                        .appendingPathComponent(fileName, isDirectory: false)
                )
                candidates.append(
                    cursor
                        .appendingPathComponent("tools", isDirectory: true)
                        .appendingPathComponent("project-code-memory", isDirectory: true)
                        .appendingPathComponent(fileName, isDirectory: false)
                )
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}
