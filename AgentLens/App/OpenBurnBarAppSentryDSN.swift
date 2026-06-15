import Foundation

#if canImport(Sentry)
extension OpenBurnBarApp {
    internal static func resolveSentryDSN(bundle: Bundle = .main) -> String? {
        if let dsn = bundle.object(forInfoDictionaryKey: "sentry.dsn") as? String,
           !dsn.trimmingCharacters(in: .whitespaces).isEmpty {
            return dsn
        }
        if let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let googleDsn = dict["sentry.dsn"] as? String,
           !googleDsn.trimmingCharacters(in: .whitespaces).isEmpty {
            return googleDsn
        }
        return nil
    }
}
#endif
