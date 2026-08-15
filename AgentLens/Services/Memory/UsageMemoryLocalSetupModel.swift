import Foundation

// MARK: - Usage-memory local model setup (U3)

extension Notification.Name {
    /// Posted by `UsageMemoryLocalSetupModel` once the local curation model(s)
    /// are downloaded and verified, so consent/settings surfaces can reflect
    /// readiness. Carries no payload.
    static let usageMemoryLocalModelSetupCompleted =
        Notification.Name("UsageMemoryLocalModelSetupCompleted")
}

/// Drives the U3 local-model setup wizard: detect a running Ollama, pull the
/// curation text model (and optionally the vision model) with streamed
/// progress, verify, done.
///
/// Boundaries (deliberate):
///  - The app NEVER downloads or installs Ollama itself. The `ollamaMissing`
///    state only links out to https://ollama.com/download and re-polls.
///  - Writes no settings. Placement/persistence is U2's domain; model names
///    come from `SummarySettings` and are left untouched.
///  - Privacy: nothing beyond model names and byte counts is retained in
///    state, and nothing is logged.
///
/// The transport is an injectable `URLSession` so tests drive the whole state
/// machine through a `URLProtocol` stub (no real network), mirroring
/// `MemoryActivationHTTPStub`.
@Observable
@MainActor
final class UsageMemoryLocalSetupModel {
    enum State: Equatable {
        /// Probing `{base}/api/tags` for a running Ollama.
        case checking
        /// No Ollama answered. The wizard links out and re-polls.
        case ollamaMissing
        /// Ollama is up; `installed` are the model names it already serves.
        case readyToDownload(installed: [String])
        /// Pulling `model`; `progress` is aggregated 0…1 across layers and is
        /// monotonic per model. Byte counters back the "X of Y MB" label.
        case downloading(model: String, progress: Double, completedBytes: Int64, totalBytes: Int64)
        /// Pulls finished; re-listing tags to confirm the models are served.
        case verifying
        /// Everything required is installed and verified.
        case done
        /// Something broke. `retryable` failures re-run the download path.
        case failed(message: String, retryable: Bool)
    }

    private struct SetupError: Error {
        let message: String
    }

    private(set) var state: State = .checking

    /// Invoked after every state transition (already on the MainActor). Used
    /// by tests to assert intermediate states (e.g. monotonic progress) that
    /// an awaited call would otherwise skip past.
    var onStateChange: ((State) -> Void)?

    private let settingsManager: SettingsManager
    private let session: URLSession
    private var recheckTimer: Timer?

    static let defaultTextModel = "qwen3.5:9b"

    init(settingsManager: SettingsManager, session: URLSession = .shared) {
        self.settingsManager = settingsManager
        self.session = session
    }

    // MARK: Model requirements (from SummarySettings, never written back)

    private var baseURL: String {
        let raw = settingsManager.summaryLocalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "http://127.0.0.1:11434" : raw
    }

    /// The curation text model. Falls back to the shipped default when the
    /// setting is empty so the wizard never pulls an empty name.
    var requiredTextModel: String {
        let raw = settingsManager.summaryLocalModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? Self.defaultTextModel : raw
    }

    /// The optional vision model (U5). `nil` = images are skipped locally, and
    /// the wizard hides the vision toggle entirely.
    var visionModel: String? {
        let raw = settingsManager.summary.usageMemoryLocalVLModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    // MARK: Detection

    /// Probes `{base}/api/tags` (2s timeout). Reachable ⇒ `readyToDownload`
    /// with the installed model names; unreachable ⇒ `ollamaMissing`. A
    /// re-poll from `ollamaMissing` stays on that state until Ollama answers,
    /// so the guidance UI doesn't flicker through `checking` every 3 seconds.
    func detect() async {
        if state != .ollamaMissing {
            transition(to: .checking)
        }
        do {
            let installed = try await fetchInstalledModels()
            transition(to: .readyToDownload(installed: installed))
        } catch {
            transition(to: .ollamaMissing)
        }
    }

    /// Auto re-poll while the wizard sits on `ollamaMissing` (started by the
    /// view on appear, cancelled on disappear). The timer only re-detects on
    /// that step — it never interrupts a download.
    func beginAutoRecheck() {
        guard recheckTimer == nil else { return }
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .ollamaMissing else { return }
                await self.detect()
            }
        }
    }

    func endAutoRecheck() {
        recheckTimer?.invalidate()
        recheckTimer = nil
    }

    // MARK: Setup

    /// Pulls the required text model (if absent) and, when `includeVision`,
    /// the vision model (if configured and absent); then re-verifies against
    /// `/api/tags` and marks `done` (posting
    /// `.usageMemoryLocalModelSetupCompleted`). Safe to call again from
    /// `failed` — it re-fetches the installed list so completed pulls are not
    /// repeated.
    func startSetup(includeVision: Bool) async {
        let installed: [String]
        if case .readyToDownload(let names) = state {
            installed = names
        } else {
            installed = (try? await fetchInstalledModels()) ?? []
        }

        var pulls: [String] = []
        let textModel = requiredTextModel
        if !Self.isInstalled(textModel, in: installed) {
            pulls.append(textModel)
        }
        let wantedVision = includeVision ? visionModel : nil
        if let wantedVision, !Self.isInstalled(wantedVision, in: installed) {
            pulls.append(wantedVision)
        }

        do {
            for model in pulls {
                try await pull(model: model)
            }
        } catch let error as SetupError {
            transition(to: .failed(message: error.message, retryable: true))
            return
        } catch {
            transition(to: .failed(
                message: "Download failed: \(error.localizedDescription)",
                retryable: true
            ))
            return
        }

        transition(to: .verifying)
        do {
            let verified = try await fetchInstalledModels()
            var missing = Self.isInstalled(textModel, in: verified) ? [] : [textModel]
            if let wantedVision, !Self.isInstalled(wantedVision, in: verified) {
                missing.append(wantedVision)
            }
            guard missing.isEmpty else {
                transition(to: .failed(
                    message: "Ollama finished downloading but is not serving \(missing.joined(separator: ", ")) yet.",
                    retryable: true
                ))
                return
            }
            transition(to: .done)
            NotificationCenter.default.post(name: .usageMemoryLocalModelSetupCompleted, object: nil)
        } catch {
            transition(to: .failed(
                message: "Ollama stopped responding while verifying the installed models.",
                retryable: true
            ))
        }
    }

    // MARK: Transport

    private func fetchInstalledModels() async throws -> [String] {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            throw SetupError(message: "The local model server address is invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SetupError(message: "Ollama did not answer the model listing.")
        }
        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]?
        }
        let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
        return (tags.models ?? []).map(\.name)
    }

    /// One NDJSON line of `POST /api/pull` progress: layer lines carry
    /// `digest`/`total`/`completed`, the final line is `{"status":"success"}`,
    /// and server-side failures arrive as `{"error": …}` mid-stream.
    private struct PullLine: Decodable {
        let status: String?
        let digest: String?
        let total: Int64?
        let completed: Int64?
        let error: String?
    }

    private func pull(model name: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/pull") else {
            throw SetupError(message: "The local model server address is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: JSONFragment] = ["name": .string(name), "stream": .bool(true)]
        request.httpBody = try JSONEncoder().encode(body)

        transition(to: .downloading(model: name, progress: 0, completedBytes: 0, totalBytes: 0))

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SetupError(message: "Ollama refused the download request for \(name).")
        }

        // Layers appear incrementally, so a naive Σcompleted/Σtotal dips every
        // time a new layer joins the denominator. Clamp to the running max so
        // the bar the user watches only ever moves forward.
        var layers: [String: (completed: Int64, total: Int64)] = [:]
        var monotonicProgress = 0.0
        var sawSuccess = false

        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let update = try? decoder.decode(PullLine.self, from: data) else {
                continue
            }
            if let message = update.error {
                throw SetupError(message: message)
            }
            if update.status == "success" {
                sawSuccess = true
            }
            if let digest = update.digest, let total = update.total, total > 0 {
                layers[digest] = (completed: update.completed ?? 0, total: total)
            }
            let completedBytes = layers.values.reduce(Int64(0)) { $0 + $1.completed }
            let totalBytes = layers.values.reduce(Int64(0)) { $0 + $1.total }
            if totalBytes > 0 {
                monotonicProgress = max(
                    monotonicProgress,
                    min(1, Double(completedBytes) / Double(totalBytes))
                )
            }
            transition(to: .downloading(
                model: name,
                progress: sawSuccess ? 1 : monotonicProgress,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            ))
        }

        guard sawSuccess else {
            throw SetupError(message: "The download for \(name) ended before completing.")
        }
    }

    // MARK: Helpers

    /// Ollama treats a tagless name as `:latest`; normalize both sides so
    /// "qwen3.5" matches an installed "qwen3.5:latest" and vice versa.
    static func isInstalled(_ model: String, in installed: [String]) -> Bool {
        func normalized(_ name: String) -> String {
            name.contains(":") ? name : "\(name):latest"
        }
        let wanted = normalized(model)
        return installed.contains { normalized($0) == wanted }
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange?(newState)
    }
}

/// Minimal heterogeneous JSON value for the pull request body
/// (`{"name": <string>, "stream": true}`) without hand-rolled string JSON.
private enum JSONFragment: Encodable {
    case string(String)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}
