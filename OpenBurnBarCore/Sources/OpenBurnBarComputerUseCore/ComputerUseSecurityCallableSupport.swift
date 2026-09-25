import Foundation

/// Choke-point alias for the untyped Firestore payload boundary in this module.
public typealias ComputerUseJSONObject = [String: Any]

/// Wave 3.4 union of the pure helpers previously duplicated in the macOS /
/// iOS `ComputerUseSecurityCallableClient` twins. The Firebase-bound callable
/// surface stays in each app target
/// (`ComputerUseSecurityCallableClient+AgentLens.swift` /
/// `ComputerUseSecurityCallableClient+Mobile.swift`); only the
/// platform-agnostic payload shaping lives here so the two clients cannot
/// drift.
public enum ComputerUseSecurityCallableSupport {
    /// Sanitizes provider account ids the same way `accountIDFor` does server-side.
    public static func providerAccountSubjectId(provider: String, accountID: String?) -> String {
        let raw: String
        if let accountID, !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Preserve the ORIGINAL (untrimmed) account id; the sanitizer below
            // collapses and edge-trims the whitespace-derived hyphens.
            raw = accountID
        } else {
            raw = "\(provider)_default"
        }
        let sanitized = sanitizedProviderAccountSubjectFragment(raw)
        let fallback = sanitizedProviderAccountSubjectFragment("\(provider)_default")
        return sanitized.isEmpty ? fallback : sanitized
    }

    private static func sanitizedProviderAccountSubjectFragment(_ raw: String) -> String {
        var collapsed = ""
        var previousWasHyphen = false
        for scalar in raw.lowercased().unicodeScalars {
            let fragment: String
            switch scalar.value {
            case 48...57, 97...122, 95:
                fragment = String(scalar)
            case 45:
                fragment = "-"
            default:
                fragment = "-"
            }
            if fragment == "-" {
                guard !previousWasHyphen else { continue }
                previousWasHyphen = true
            } else {
                previousWasHyphen = false
            }
            collapsed.append(fragment)
        }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Narrows an untyped JSON object to a provably `Sendable` one.
    ///
    /// Mission payloads arrive from Firestore as `[String: Any]`, but
    /// `callHighRiskOwnerAction` deliberately requires `Sendable` (tightened by the
    /// high-risk-owner-action security work). `as? any Sendable` cannot express that --
    /// `Sendable` is a marker protocol and Swift rejects it in a conditional cast -- so
    /// recognise the JSON value types instead. Anything unrecognised is dropped rather
    /// than force-cast: a payload reaching the wire while carrying a non-Sendable
    /// reference is exactly the race the requirement exists to prevent.
    public static func sendableJSONPayload(_ object: ComputerUseJSONObject) -> [String: any Sendable] {
        object.reduce(into: [String: any Sendable]()) { result, entry in
            if let value = sendableJSONValue(entry.value) {
                result[entry.key] = value
            }
        }
    }

    private static func sendableJSONValue(_ value: Any) -> (any Sendable)? {
        switch value {
        case let value as String: return value
        case let value as Bool: return value
        case let value as Int: return value
        case let value as Double: return value
        case let value as NSNumber: return value.doubleValue
        case is NSNull: return nil
        case let value as [Any]: return value.compactMap(sendableJSONValue)
        case let value as ComputerUseJSONObject: return sendableJSONPayload(value)
        default: return nil
        }
    }
}
