import Foundation
import SwiftUI
import OpenBurnBarCore

// MARK: - Composition Root (WP3-IOSROOT)
//
// OpenBurnBarMobile grew a 62-singleton service mesh with direct
// service-to-service `.shared` calls and no composition layer
// (TECH_DEBT_AUDIT_2026-06-11 §11 "Composition roots", Appendix A #20).
// `AppServices` is the incremental fix: a plain struct built once in
// `OpenBurnBarMobileApp` and exposed through the SwiftUI environment so
// views and services can resolve long-lived dependencies from one root
// instead of reaching for globals.
//
// Migration contract (incremental and additive — never big-bang):
//   * Existing `.shared` singletons KEEP WORKING unchanged. During the
//     migration this root exposes the very same instances; nothing is
//     constructed twice and no caller has to move before it is ready.
//   * Accessors are computed (resolved on first read), deliberately not
//     stored. Storing the instances here would force `HermesService.shared`
//     and friends to initialize while the `App` struct is created — before
//     `AppDelegate.application(_:didFinishLaunchingWithOptions:)` has run
//     `FirebaseApp.configure()` — which would change today's launch
//     ordering. Flipping each accessor to a stored `let` (true ownership)
//     is the per-service follow-up once its launch-order is audited.
//   * New code takes dependencies via `init` (see
//     `PiService.init(runtimeCatalogProvider:)`) or reads
//     `@Environment(\.appServices)`; new `.shared` edges are exactly what
//     this type exists to stop.
//
// The chat triangle (HermesService / PiService / CLIAgentMobileChatService,
// Appendix A #132) migrates first to prove the pattern:
//   * `HermesService` — provider side: conforms to
//     `CLIRuntimeCatalogProviding` below (it already had the method; the
//     conformance is purely declarative).
//   * `PiService` — consumer side: takes the catalog provider via `init`
//     instead of calling `HermesService.shared` inline.
//   * `CLIAgentMobileChatService` — already injects
//     `CLIAgentRelayChatTransporting` via `init`; the root exposes the
//     production transport so construction sites can resolve it here
//     instead of naming `CLIAgentRelayChatTransport.shared`.

// MARK: - CLI Runtime Catalog Seam

/// The Mac-relay CLI model-catalog fetch the chat-runtime services all reach
/// for (the Pi/OpenClaw relay model-discovery fallback, CLI-agent preferred
/// model validation, and the assistant model picker). `HermesService` is the
/// production provider; this protocol exists so consumers can take the
/// dependency via `init` (injectable in tests) instead of hard-coding
/// `HermesService.shared`.
@MainActor
protocol CLIRuntimeCatalogProviding: AnyObject {
    /// Fetches the live model catalog the paired Mac advertises for one CLI
    /// runtime. See `HermesService.fetchCLIRuntimeModelCatalog(runtime:)` —
    /// the production implementation — for the relay transport details.
    func fetchCLIRuntimeModelCatalog(runtime: AssistantRuntimeID) async throws -> CLIRuntimeModelCatalogResponse
}

/// Production provider. `HermesService` already exposes
/// `fetchCLIRuntimeModelCatalog(runtime:)` with exactly the protocol's
/// signature, so this conformance adds no code and changes no behavior.
extension HermesService: CLIRuntimeCatalogProviding {}

// MARK: - App Services

/// The app's composition root. Built once in `OpenBurnBarMobileApp` and
/// injected via `\.appServices`. Constructing the value has **no side
/// effects** — it stores nothing; each accessor resolves the existing
/// long-lived singleton on first read, preserving today's lazy
/// initialization order exactly.
struct AppServices {
    /// Shared Hermes runtime/catalog surface. Same instance as
    /// `HermesService.shared` (per-surface conversation state still lives in
    /// per-surface instances; see the doc on `HermesService.shared`).
    @MainActor var hermes: HermesService { .shared }

    /// Pi assistant runtime. Same instance as `PiService.shared`
    /// (long-running views still construct their own instance, unchanged).
    @MainActor var pi: PiService { .shared }

    /// Relay chat transport `CLIAgentMobileChatService` streams through.
    /// Same instance as `CLIAgentRelayChatTransport.shared`.
    @MainActor var cliAgentChatTransport: any CLIAgentRelayChatTransporting {
        CLIAgentRelayChatTransport.shared
    }

    /// The CLI-runtime model-catalog provider (the chat-triangle seam).
    /// Same instance as `HermesService.shared`.
    @MainActor var runtimeCatalog: any CLIRuntimeCatalogProviding { hermes }
}

// MARK: - Environment Plumbing

private struct AppServicesEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppServices()
}

extension EnvironmentValues {
    /// The composition root for long-lived services. Defaults to the
    /// production graph, so previews and tests that don't override it keep
    /// today's behavior; tests can swap in a fixture root with
    /// `.environment(\.appServices, ...)`.
    var appServices: AppServices {
        get { self[AppServicesEnvironmentKey.self] }
        set { self[AppServicesEnvironmentKey.self] = newValue }
    }
}
