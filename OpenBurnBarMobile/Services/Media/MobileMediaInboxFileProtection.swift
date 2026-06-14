import Foundation

public enum MobileMediaInboxFileProtection {
    public static func apply(to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}
