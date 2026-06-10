import Foundation

/// Fixed-time equality for authentication secrets.
///
/// SECURITY (L6): the daemon control socket and the local HTTP gateway compare a
/// presented auth token against the configured one. Swift's `==` on `String`
/// short-circuits on the first differing byte, which is a timing oracle. Although
/// the tokens here are high-entropy and the surface is local/loopback, the gateway
/// can be bound beyond loopback, so we compare in time independent of where the
/// first mismatch occurs. The byte-length is intentionally folded into the result
/// without leaking via an early return.
@inline(never)
func constantTimeTokensEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    var diff = UInt32(a.count ^ b.count)
    let n = max(a.count, b.count)
    var index = 0
    while index < n {
        let x: UInt8 = index < a.count ? a[index] : 0
        let y: UInt8 = index < b.count ? b[index] : 0
        diff |= UInt32(x ^ y)
        index += 1
    }
    return diff == 0
}
