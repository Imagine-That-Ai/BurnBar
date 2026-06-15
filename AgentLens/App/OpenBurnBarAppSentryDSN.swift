import Foundation

#if canImport(Sentry)
extension OpenBurnBarApp {
    internal static func resolveSentryDSN(bundle: Bundle = .main) -> String? {
        if let dsn = bundle.object(forInfoDictionaryKey: "sentry.dsn") as? String {
            let trimmed = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let googleDsn = dict["sentry.dsn"] as? String {
            let trimmed = googleDsn.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
#endif
