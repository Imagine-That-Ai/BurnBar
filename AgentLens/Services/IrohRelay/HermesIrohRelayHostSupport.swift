import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
import FirebaseRemoteConfig
import Foundation
import OpenBurnBarIrohRelay
import os

actor IrohRelayLifecycleGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

enum HermesIrohHostedRelayConfig {
    private static let remoteConfigKey = "hermes_iroh_hosted_relay_url"
    private static let userDefaultsKey = "hermes_iroh_hosted_relay_url"
    private static let environmentKey = "OPENBURNBAR_IROH_HOSTED_RELAY_URL"

    static func refreshRemoteConfigIfAvailable() async {
        guard !hasLocalOverride else { return }
        guard FirebaseApp.app() != nil else { return }
        let remoteConfig = RemoteConfig.remoteConfig()
        remoteConfig.setDefaults([remoteConfigKey: "" as NSObject])
        await withCheckedContinuation { continuation in
            let gate = ContinuationGate(continuation)
            remoteConfig.fetchAndActivate { _, _ in
                gate.resume()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                gate.resume()
            }
        }
    }

    static func currentURL() -> String? {
        normalized(ProcessInfo.processInfo.environment[environmentKey])
            ?? normalized(UserDefaults.standard.string(forKey: userDefaultsKey))
            ?? currentRemoteConfigURL()
    }

    private static func currentRemoteConfigURL() -> String? {
        guard FirebaseApp.app() != nil else { return nil }
        return normalized(RemoteConfig.remoteConfig().configValue(forKey: remoteConfigKey).stringValue)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static var hasLocalOverride: Bool {
        normalized(ProcessInfo.processInfo.environment[environmentKey]) != nil
            || normalized(UserDefaults.standard.string(forKey: userDefaultsKey)) != nil
    }

    private final class ContinuationGate: Sendable {
        // `CheckedContinuation` is not `Sendable`, so the once-only flag and the
        // continuation share a single unfair-lock-protected `State`. Resuming
        // inside the lock keeps the resume-exactly-once guarantee the prior
        // `NSLock` version provided.
        private struct State {
            var didResume = false
            let continuation: CheckedContinuation<Void, Never>
        }

        private let state: OSAllocatedUnfairLock<State>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            state = OSAllocatedUnfairLock(uncheckedState: State(continuation: continuation))
        }

        func resume() {
            state.withLockUnchecked { state in
                guard !state.didResume else { return }
                state.didResume = true
                state.continuation.resume()
            }
        }
    }
}

extension HermesIrohRelayHostClient {
    func isCurrentTransport(_ candidate: any IrohRelayTransport) -> Bool {
        guard let transport else { return false }
        return transport === candidate
    }

    func isCurrentRuntimeOwner(_ owner: RuntimeOwner) -> Bool {
        desiredRuntimeOwner == owner
    }
}
