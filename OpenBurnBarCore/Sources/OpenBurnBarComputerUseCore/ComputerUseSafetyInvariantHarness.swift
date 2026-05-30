import Foundation

/// Exhaustive FSM explorer for Computer Use safety invariants (WS6 CI gate).
///
/// Models approval / trust / panic / grant transitions abstractly so property-based
/// and exhaustive tests can assert:
/// - no privileged input after any panic source;
/// - revoked / expired grants produce no effect and are audited;
/// - trust only downgrades without explicit Mac UI approval;
/// - Remote Unlock capability tokens are single-use and domain-locked.
public enum ComputerUseSafetyInvariantHarness: Sendable {
    public enum SessionPhase: String, CaseIterable, Sendable {
        case idle
        case activeManual
        case activeTrusted
        case panicHalted
    }

    public enum Stimulus: String, CaseIterable, Sendable {
        case beginManualSession
        case beginTrustedSession
        case inputAction
        case panic
        case grantApplyFresh
        case grantApplyExpired
        case grantApplyRevoked
        case trustEscalateWithoutApproval
        case trustDowngrade
        case clearPanic
    }

    public enum AuditEvent: String, Sendable, Equatable {
        case inputDeniedPanic
        case inputExecuted
        case grantApplied
        case grantDeniedExpired
        case grantDeniedRevoked
        case trustEscalationRejected
        case trustDowngraded
        case panicHalted
        case tokenRedeemed
        case tokenDeniedReuse
        case tokenDeniedDomainMismatch
        case tokenDeniedExpired
    }

    public struct SessionModel: Sendable, Equatable {
        public var phase: SessionPhase
        public var liveTrust: ComputerUseTrustMode
        public var grantActive: Bool
        public var inputsSincePanic: Int

        public init(
            phase: SessionPhase = .idle,
            liveTrust: ComputerUseTrustMode = .manual,
            grantActive: Bool = false,
            inputsSincePanic: Int = 0
        ) {
            self.phase = phase
            self.liveTrust = liveTrust
            self.grantActive = grantActive
            self.inputsSincePanic = inputsSincePanic
        }
    }

    public struct TransitionResult: Sendable, Equatable {
        public var model: SessionModel
        public var audit: [AuditEvent]
        public var inputAllowed: Bool

        public init(model: SessionModel, audit: [AuditEvent], inputAllowed: Bool) {
            self.model = model
            self.audit = audit
            self.inputAllowed = inputAllowed
        }
    }

    /// Single-use nonce ledger for capability tokens (harness + leaf verification).
    public struct CapabilityTokenRedemptionLedger: Sendable {
        private var redeemedNonces: Set<String> = []

        public init() {}

        public mutating func redeem(_ token: CapabilityToken, expectedDomain: CapabilityToken.Domain) -> Result<Void, TokenRedemptionFailure> {
            if token.isExpired() {
                return .failure(.expired)
            }
            guard token.domain == expectedDomain else {
                return .failure(.domainMismatch(expected: expectedDomain, actual: token.domain))
            }
            guard redeemedNonces.insert(token.nonce).inserted else {
                return .failure(.reuse)
            }
            return .success(())
        }
    }

    public enum TokenRedemptionFailure: Error, Equatable, Sendable {
        case expired
        case reuse
        case domainMismatch(expected: CapabilityToken.Domain, actual: CapabilityToken.Domain)
    }

    public static func transition(_ model: SessionModel, stimulus: Stimulus) -> TransitionResult {
        var next = model
        var audit: [AuditEvent] = []
        var inputAllowed = false

        switch stimulus {
        case .beginManualSession:
            next.phase = .activeManual
            next.liveTrust = .manual
            next.grantActive = false
            next.inputsSincePanic = 0

        case .beginTrustedSession:
            next.phase = .activeTrusted
            next.liveTrust = .trusted
            next.grantActive = true
            next.inputsSincePanic = 0

        case .inputAction:
            if next.phase == .panicHalted {
                audit.append(.inputDeniedPanic)
                inputAllowed = false
            } else if next.phase == .idle {
                inputAllowed = false
            } else {
                audit.append(.inputExecuted)
                inputAllowed = true
                next.inputsSincePanic += 1
            }

        case .panic:
            next.phase = .panicHalted
            next.grantActive = false
            audit.append(.panicHalted)
            inputAllowed = false

        case .grantApplyFresh:
            if next.phase == .panicHalted || next.phase == .idle {
                inputAllowed = false
            } else {
                next.grantActive = true
                audit.append(.grantApplied)
            }

        case .grantApplyExpired:
            next.grantActive = false
            audit.append(.grantDeniedExpired)
            inputAllowed = false

        case .grantApplyRevoked:
            next.grantActive = false
            audit.append(.grantDeniedRevoked)
            inputAllowed = false

        case .trustEscalateWithoutApproval:
            if next.liveTrust == .manual || next.liveTrust == .step {
                audit.append(.trustEscalationRejected)
            }

        case .trustDowngrade:
            switch next.liveTrust {
            case .trusted:
                next.liveTrust = .step
            case .step:
                next.liveTrust = .manual
            case .manual:
                break
            }
            audit.append(.trustDowngraded)

        case .clearPanic:
            if next.phase == .panicHalted {
                next.phase = .idle
                next.inputsSincePanic = 0
            }
        }

        return TransitionResult(model: next, audit: audit, inputAllowed: inputAllowed)
    }

    /// Breadth-first exploration of all reachable `(phase, trust, grantActive)` states.
    public static func reachableStateCount(maxDepth: Int = 6) -> Int {
        var seen = Set<String>()
        var frontier = [SessionModel()]
        var depth = 0

        while !frontier.isEmpty && depth <= maxDepth {
            var nextFrontier: [SessionModel] = []
            for model in frontier {
                let key = stateKey(model)
                guard seen.insert(key).inserted else { continue }
                for stimulus in Stimulus.allCases {
                    let result = transition(model, stimulus: stimulus)
                    nextFrontier.append(result.model)
                }
            }
            frontier = nextFrontier
            depth += 1
        }
        return seen.count
    }

    /// Asserts invariants hold for every `(state, stimulus)` pair up to `maxDepth`.
    public static func verifyExhaustiveInvariants(maxDepth: Int = 5) -> [InvariantViolation] {
        var violations: [InvariantViolation] = []
        var frontier: [(SessionModel, Int)] = [(SessionModel(), 0)]
        var visited = Set<String>()

        while let (model, depth) = frontier.popLast() {
            let key = stateKey(model)
            guard visited.insert(key).inserted else { continue }
            guard depth <= maxDepth else { continue }

            for stimulus in Stimulus.allCases {
                let result = transition(model, stimulus: stimulus)

                if model.phase == .panicHalted && stimulus == .inputAction && result.inputAllowed {
                    violations.append(.inputAllowedAfterPanic)
                }
                if stimulus == .grantApplyExpired && result.audit.contains(.grantApplied) {
                    violations.append(.expiredGrantApplied)
                }
                if stimulus == .grantApplyRevoked && result.audit.contains(.grantApplied) {
                    violations.append(.revokedGrantApplied)
                }
                if stimulus == .trustEscalateWithoutApproval && result.model.liveTrust == .trusted && model.liveTrust != .trusted {
                    violations.append(.trustEscalatedWithoutApproval)
                }
                if stimulus == .panic && result.model.phase != .panicHalted {
                    violations.append(.panicDidNotHalt)
                }

                frontier.append((result.model, depth + 1))
            }
        }
        return violations
    }

    public enum InvariantViolation: String, Sendable, Equatable {
        case inputAllowedAfterPanic
        case expiredGrantApplied
        case revokedGrantApplied
        case trustEscalatedWithoutApproval
        case panicDidNotHalt
    }

    private static func stateKey(_ model: SessionModel) -> String {
        "\(model.phase.rawValue)|\(model.liveTrust.rawValue)|grant:\(model.grantActive)"
    }
}
