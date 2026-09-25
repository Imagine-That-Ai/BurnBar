import Foundation

extension URL {
    /// URL from a compile-time-known literal. `StaticString` forces the
    /// argument to be a literal, so a dynamic string can never reach the
    /// single force-unwrap inside. Prefer this over `URL(string:)!`.
    public init(staticString: StaticString) {
        self = URL(string: "\(staticString)")!
    }
}
