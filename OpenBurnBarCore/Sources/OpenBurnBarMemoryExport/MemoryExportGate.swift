// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportGate — D-0008's per-class secret/PII policy on the migration path.
//
// This calls BurnBar's own `MemorySecretPIIGate`. There is no second scanner and
// no second corpus: the gate was promoted out of the daemon precisely so the app
// and daemon scanners could not drift, and a migration-only copy would be a
// third drift surface.
//
// The three classes and where they land:
//
//   * **reject** — credentials, government identifiers, payment cards,
//     high-entropy blobs. The span is replaced by `[REDACTED:<class>]` and never
//     reaches the sealed body.
//   * **redact** — email, phone, IP, street address. Replaced by a typed
//     placeholder so the fact survives.
//   * **hold** — anything the gate could not locate exactly.
//
// All three land in `imported_detail.gate_held` on the migration path, and
// `gate_classes` must sum to it, so "which class held this row" is answerable
// without opening a body. **No class drops a row**: dropping one would be
// silent loss, which is the failure mode this whole document exists to prevent.
//
// A corpus that will not load is `GATE_UNAVAILABLE` and refuses the export.
// Fail-closed here cannot mean "placeholder every body in the store".

import Foundation
import OpenBurnBarKernel

public enum MemoryExportGateClass: String, Sendable, CaseIterable {
    case reject
    case redact
    case hold
}

public struct MemoryExportGateOutcome: Sendable, Equatable {
    /// The body that actually travels. Never the raw text when the gate fired.
    public var body: String
    public var gateClass: MemoryExportGateClass?
    public var redactionState: MIFRedactionState
    public var sensitivityLabels: [String]

    public var isHeld: Bool { gateClass != nil }

    /// A gated row is quarantined regardless of what the classifier proved: a
    /// human approved text that is not the text now travelling.
    public func reviewStatus(_ classified: MIFReviewStatus) -> MIFReviewStatus {
        guard isHeld else { return classified }
        return classified == .rejected ? .rejected : .quarantined
    }

    public static func clean(_ body: String) -> MemoryExportGateOutcome {
        MemoryExportGateOutcome(body: body, gateClass: nil, redactionState: .clean, sensitivityLabels: [])
    }
}

/// The gate as a value, so a fixture can pin behaviour and the real corpus is
/// still what production calls.
public struct MemoryExportGateRunner: Sendable {
    public var isAvailable: @Sendable () -> Bool
    public var evaluate: @Sendable (String) -> MemoryGateVerdict

    public init(
        isAvailable: @escaping @Sendable () -> Bool,
        evaluate: @escaping @Sendable (String) -> MemoryGateVerdict
    ) {
        self.isAvailable = isAvailable
        self.evaluate = evaluate
    }

    /// The production gate: BurnBar's shared corpus, redaction policy, and its
    /// fail-closed behaviour untouched.
    public static let shared = MemoryExportGateRunner(
        isAvailable: { MemorySecretPIIGate.isAvailable },
        evaluate: { MemorySecretPIIGate.evaluate($0, policy: .redact) }
    )

    /// Applies D-0008 to one body.
    public func apply(to body: String) -> MemoryExportGateOutcome {
        switch evaluate(body) {
        case .allow:
            return .clean(body)

        case .redact(let redactedText, let findings):
            // Every span was located. A credential class among them still means
            // the row is held, not merely redacted: the placeholder proves the
            // secret is gone, and the review is how the user learns it was there.
            let hasSecret = findings.contains { $0.kind == .secret }
            return MemoryExportGateOutcome(
                body: redactedText,
                gateClass: hasSecret ? .reject : .redact,
                redactionState: .heldForReview,
                sensitivityLabels: labels(findings)
            )

        case .reject(let findings):
            // The gate refused: either the corpus is gone (handled before any
            // body is read) or a finding could not be located on the original
            // text. An unlocatable secret means no part of this body is safe to
            // carry, so the row travels with its metadata and a placeholder —
            // held, never dropped.
            return MemoryExportGateOutcome(
                body: "[REDACTED:unlocatable]",
                gateClass: .hold,
                redactionState: .heldForReview,
                sensitivityLabels: labels(findings)
            )
        }
    }

    private func labels(_ findings: [MemoryGateFinding]) -> [String] {
        Array(Set(findings.map(\.id))).sorted()
    }
}

/// Running totals for the report's `gate_classes` block.
public struct MemoryExportGateTally: Sendable, Equatable {
    public var reject = 0
    public var redact = 0
    public var hold = 0

    public var total: Int { reject + redact + hold }

    public mutating func record(_ outcome: MemoryExportGateOutcome) {
        switch outcome.gateClass {
        case .reject: reject += 1
        case .redact: redact += 1
        case .hold: hold += 1
        case nil: break
        }
    }
}
