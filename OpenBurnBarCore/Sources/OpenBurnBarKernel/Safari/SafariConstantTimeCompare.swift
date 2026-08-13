import Foundation

/// Fixed-time equality for Safari bridge digests.
///
/// The App Group payload resolver and the chunk store both compare a recomputed
/// SHA-256 hex digest against the one declared by the caller. Swift's `==` on
/// `String` short-circuits on the first differing byte, which is a timing
/// oracle an extension-side caller could probe. The byte-length is folded into
/// the result without leaking via an early return.
@inline(never)
func constantTimeSafariDigestsEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var difference = UInt8(left.count == right.count ? 0 : 1)
    let count = max(left.count, right.count)
    for index in 0..<count {
        let l = index < left.count ? left[index] : 0
        let r = index < right.count ? right[index] : 0
        difference |= l ^ r
    }
    return difference == 0
}
