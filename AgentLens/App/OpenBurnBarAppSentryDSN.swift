import Foundation

#if canImport(Sentry)
extension OpenBurnBarApp {
    internal static func resolveSentryDSN(bundle: Bundle = .main) -> String? {
        if let dsn = bundle.object(forInfoDictionaryKey: "sentry.dsn") as? String {
            let trimmed = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
            print("resolveSentryDSN: dsn='\(dsn)' trimmed='\(trimmed)' isEmpty=\(trimmed.isEmpty)")
            if !trimmed.isEmpty {
                return dsn
            }
        }
        if let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let googleDsn = dict["sentry.dsn"] as? String {
            let trimmed = googleDsn.trimmingCharacters(in: .whitespacesAndNewlines)
            print("resolveSentryDSN: googleDsn='\(googleDsn)' trimmed='\(trimmed)' isEmpty=\(trimmed.isEmpty)")
            if !trimmed.isEmpty {
                return googleDsn
            }
        }
        return nil
    }
}
#endif
