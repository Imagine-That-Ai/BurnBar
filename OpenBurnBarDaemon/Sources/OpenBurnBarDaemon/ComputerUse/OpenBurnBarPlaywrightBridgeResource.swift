import Foundation

enum OpenBurnBarPlaywrightBridgeResource {
    static let fileName = "openburnbar-playwright-bridge.js"
    static let installedRelativePath = "usr/lib/openburnbar/playwright/\(fileName)"
    static let packagedEnvironmentKey = "OPENBURNBAR_PACKAGED_PLAYWRIGHT_BRIDGE"
    static let developmentEnvironmentKey = "OPENBURNBAR_PLAYWRIGHT_BRIDGE"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        currentDirectoryURL: URL? = nil
    ) -> URL {
#if os(Linux)
        if let installed = installedLinuxURL(environment: environment, fileManager: fileManager) {
            return installed
        }
#endif
        if let override = absoluteFileURL(environment[developmentEnvironmentKey]) {
            return override
        }
        let cwd = currentDirectoryURL
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates = [
            bundleResourceURL?
                .appendingPathComponent("PlaywrightBridge", isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false),
            cwd.appendingPathComponent(
                "OpenBurnBarDaemon/Resources/PlaywrightBridge/\(fileName)",
                isDirectory: false
            ),
            cwd.appendingPathComponent(
                "Resources/PlaywrightBridge/\(fileName)",
                isDirectory: false
            )
        ].compactMap { $0 }
        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
            ?? candidates[0]
    }

    static func installedLinuxURL(
        environment: [String: String],
        fileManager: FileManager,
        systemRoot: URL = URL(fileURLWithPath: "/", isDirectory: true)
    ) -> URL? {
        if let packaged = absoluteFileURL(environment[packagedEnvironmentKey]) {
            return packaged
        }
        if let appDirectory = absoluteDirectoryURL(environment["APPDIR"]) {
            return appDirectory.appendingPathComponent(installedRelativePath, isDirectory: false)
        }
        let system = systemRoot.appendingPathComponent(installedRelativePath, isDirectory: false)
        return fileManager.fileExists(atPath: system.path) ? system : nil
    }

    private static func absoluteFileURL(_ rawValue: String?) -> URL? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: value, isDirectory: false).standardizedFileURL
    }

    private static func absoluteDirectoryURL(_ rawValue: String?) -> URL? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }
}
