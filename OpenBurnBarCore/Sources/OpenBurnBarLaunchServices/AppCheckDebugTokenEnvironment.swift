import Foundation

public enum AppCheckDebugTokenEnvironment {
    public static let firebaseDebugTokenKey = "FirebaseAppCheckDebugToken"
    public static let firaDebugTokenKey = "FIRAAppCheckDebugToken"
    public static let useDebugAppCheckInfoKey = "OpenBurnBarUseDebugAppCheck"

    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public static func debugAppCheckAllowed(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        isDebugBuild: Bool = Self.isDebugBuild
    ) -> Bool {
        if isDebugBuild {
            return true
        }
        return truthy(infoDictionary?[useDebugAppCheckInfoKey])
    }

    @discardableResult
    public static func configureIfAvailable(
        firebasePlistPath: String?,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        debugAppCheckAllowed: Bool? = nil,
        setEnvironment: (String, String, Int32) -> Int32 = { key, value, overwrite in
            setenv(key, value, overwrite)
        }
    ) -> String? {
        let allowed = debugAppCheckAllowed ?? Self.debugAppCheckAllowed(infoDictionary: infoDictionary)
        guard allowed,
              let token = availableToken(
                firebasePlistPath: firebasePlistPath,
                infoDictionary: infoDictionary,
                environment: environment
              ) else {
            return nil
        }

        if environment[firaDebugTokenKey]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            _ = setEnvironment(firaDebugTokenKey, token, 0)
        }
        if environment[firebaseDebugTokenKey]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            _ = setEnvironment(firebaseDebugTokenKey, token, 0)
        }
        return token
    }

    public static func availableToken(
        firebasePlistPath: String?,
        infoDictionary: [String: Any]?,
        environment: [String: String]
    ) -> String? {
        token(inEnvironment: environment)
            ?? token(in: infoDictionary)
            ?? token(inPlistAt: firebasePlistPath)
    }

    public static func token(in infoDictionary: [String: Any]?) -> String? {
        tokenValue(infoDictionary?[firaDebugTokenKey])
            ?? tokenValue(infoDictionary?[firebaseDebugTokenKey])
    }

    public static func token(inEnvironment environment: [String: String]) -> String? {
        tokenValue(environment[firaDebugTokenKey])
            ?? tokenValue(environment[firebaseDebugTokenKey])
    }

    public static func token(inPlistAt path: String?) -> String? {
        guard let path,
              let dictionary = NSDictionary(contentsOfFile: path) as? [String: Any]
        else {
            return nil
        }
        return token(in: dictionary)
    }

    private static func tokenValue(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func truthy(_ raw: Any?) -> Bool {
        switch raw {
        case let value as Bool:
            return value
        case let value as String:
            return ["1", "true", "yes", "y"]
                .contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }
}
