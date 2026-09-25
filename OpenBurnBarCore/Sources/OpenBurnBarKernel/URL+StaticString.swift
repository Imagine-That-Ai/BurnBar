import Foundation

extension URL {
    /// URL from a compile-time-known literal. `StaticString` forces the
    /// argument to be a literal, so a dynamic string can never reach this
    /// initializer. Prefer this over `URL(string:)!`.
    public init(staticString: StaticString) {
        // A literal that is not a valid URL is a programmer error caught in
        // development; fall back to an inert value rather than crashing.
        self = URL(string: "\(staticString)") ?? URL(fileURLWithPath: "/")
    }
}
