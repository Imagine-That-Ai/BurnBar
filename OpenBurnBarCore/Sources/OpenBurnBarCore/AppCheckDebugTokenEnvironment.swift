import Foundation

public enum AppCheckDebugTokenEnvironment {
    public static let firebaseDebugTokenKey = "FirebaseAppCheckDebugToken"
    public static let firaDebugTokenKey = "FIRAAppCheckDebugToken"

    @discardableResult
    public static func configureIfAvailable(
        firebasePlistPath: String?,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        setEnvironment: (String, String, Int32) -> Int32 = { key, value, overwrite in
            setenv(key, value, overwrite)
        }
    ) -> String? {
        guard let token = existingToken(in: environment)
            ?? token(in: infoDictionary)
            ?? token(inPlistAt: firebasePlistPath)
        else {
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

    public static func token(in infoDictionary: [String: Any]?) -> String? {
        tokenValue(infoDictionary?[firaDebugTokenKey])
            ?? tokenValue(infoDictionary?[firebaseDebugTokenKey])
    }

    public static func token(inPlistAt path: String?) -> String? {
        guard let path,
              let dictionary = NSDictionary(contentsOfFile: path) as? [String: Any]
        else {
            return nil
        }
        return token(in: dictionary)
    }

    private static func existingToken(in environment: [String: String]) -> String? {
        tokenValue(environment[firaDebugTokenKey])
            ?? tokenValue(environment[firebaseDebugTokenKey])
    }

    private static func tokenValue(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
