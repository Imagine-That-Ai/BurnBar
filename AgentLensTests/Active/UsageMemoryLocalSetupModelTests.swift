import XCTest
@testable import OpenBurnBar

/// U3: the local-model setup wizard's state machine + Ollama transport,
/// driven end to end through a `URLProtocol` stub (no real network),
/// mirroring `MemoryActivationHTTPStub`.
///
/// Invariants under test:
///  - **Detection:** `/api/tags` 200 ⇒ `readyToDownload` with the installed
///    names (and already-installed models are never re-pulled); connection
///    refused ⇒ `ollamaMissing`.
///  - **Pull streaming:** NDJSON layer lines aggregate to a *monotonic* 0…1
///    progress (new layers growing the denominator never move the bar
///    backwards) and end in `done`; a mid-stream `{"error": …}` line fails
///    retryably.
///  - **Model set:** `includeVision` pulls text then vision, in order; vision
///    stays untouched otherwise, and an empty `usageMemoryLocalVLModel`
///    means no vision pull even when requested.
///  - **Completion:** success posts `.usageMemoryLocalModelSetupCompleted`.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
@MainActor
final class UsageMemoryLocalSetupModelTests: XCTestCase {

    private var settingsManager: SettingsManager!

    private let textModel = "qwen3.5:9b"
    private let visionModel = "qwen3-vl:8b"

    override func setUp() {
        super.setUp()
        LocalSetupHTTPStub.reset()
        settingsManager = makeSettingsManager()
        settingsManager.summaryLocalModel = textModel
        settingsManager.summary.usageMemoryLocalVLModel = visionModel
    }

    override func tearDown() {
        LocalSetupHTTPStub.reset()
        settingsManager = nil
        super.tearDown()
    }

    private func makeModel() -> UsageMemoryLocalSetupModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalSetupHTTPStub.self]
        return UsageMemoryLocalSetupModel(
            settingsManager: settingsManager,
            session: URLSession(configuration: config)
        )
    }

    // MARK: - Detection

    func testDetectWithModelPresentReportsInstalledAndSkipsItsPull() async {
        LocalSetupHTTPStub.installedModels = [textModel]

        let model = makeModel()
        await model.detect()
        XCTAssertEqual(model.state, .readyToDownload(installed: [textModel]))

        await model.startSetup(includeVision: false)
        XCTAssertEqual(LocalSetupHTTPStub.pullRequests, [], "installed model must not be re-pulled")
        XCTAssertEqual(model.state, .done)
    }

    func testDetectConnectionRefusedReportsOllamaMissing() async {
        LocalSetupHTTPStub.tagsFails = true

        let model = makeModel()
        await model.detect()
        XCTAssertEqual(model.state, .ollamaMissing)
    }

    // MARK: - Pull streaming

    func testPullStreamAggregatesMonotonicProgressReachingDone() async {
        LocalSetupHTTPStub.installedModels = []
        // Layer B joins after layer A is half done: naive Σcompleted/Σtotal
        // would dip 0.5 → 0.25 on the third line; the model must clamp.
        LocalSetupHTTPStub.pullScripts[textModel] = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"pulling a","digest":"sha256:a","total":100,"completed":50}"#,
            #"{"status":"pulling b","digest":"sha256:b","total":100,"completed":0}"#,
            #"{"status":"pulling a","digest":"sha256:a","total":100,"completed":100}"#,
            #"{"status":"pulling b","digest":"sha256:b","total":100,"completed":100}"#,
            #"{"status":"verifying sha256 digest"}"#,
            #"{"status":"success"}"#
        ]

        let model = makeModel()
        var progresses: [Double] = []
        var byteCounts: [(completed: Int64, total: Int64)] = []
        model.onStateChange = { state in
            if case .downloading(_, let progress, let completed, let total) = state {
                progresses.append(progress)
                byteCounts.append((completed, total))
            }
        }

        await model.detect()
        await model.startSetup(includeVision: false)

        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(progresses.last, 1)
        XCTAssertEqual(progresses, progresses.sorted(), "progress must be monotonic")
        // The dip line (Σ 50/200 = 0.25) must have been clamped at 0.5.
        XCTAssertTrue(progresses.contains(0.5))
        XCTAssertFalse(progresses.contains(0.25))
        // Byte counters stay raw for the "X of Y MB" label.
        XCTAssertEqual(byteCounts.last?.completed, 200)
        XCTAssertEqual(byteCounts.last?.total, 200)
    }

    func testMidStreamErrorLineFailsRetryable() async {
        LocalSetupHTTPStub.installedModels = []
        LocalSetupHTTPStub.pullScripts[textModel] = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"pulling a","digest":"sha256:a","total":100,"completed":10}"#,
            #"{"error":"pull model manifest: file does not exist"}"#
        ]

        let model = makeModel()
        await model.detect()
        await model.startSetup(includeVision: false)

        XCTAssertEqual(
            model.state,
            .failed(message: "pull model manifest: file does not exist", retryable: true)
        )
    }

    // MARK: - Model set

    func testIncludeVisionPullsBothModelsInOrder() async {
        LocalSetupHTTPStub.installedModels = []

        let model = makeModel()
        await model.detect()
        await model.startSetup(includeVision: true)

        XCTAssertEqual(LocalSetupHTTPStub.pullRequests, [textModel, visionModel])
        XCTAssertEqual(model.state, .done)
    }

    func testVisionAbsentWithoutIncludeVisionPullsTextOnly() async {
        LocalSetupHTTPStub.installedModels = []

        let model = makeModel()
        await model.detect()
        await model.startSetup(includeVision: false)

        XCTAssertEqual(LocalSetupHTTPStub.pullRequests, [textModel])
        XCTAssertEqual(model.state, .done)
    }

    func testEmptyVLModelSettingSkipsVisionEvenWhenRequested() async {
        settingsManager.summary.usageMemoryLocalVLModel = ""
        LocalSetupHTTPStub.installedModels = []

        let model = makeModel()
        await model.detect()
        await model.startSetup(includeVision: true)

        XCTAssertEqual(LocalSetupHTTPStub.pullRequests, [textModel])
        XCTAssertEqual(model.state, .done)
    }

    // MARK: - Completion notification

    func testSuccessPostsSetupCompletedNotification() async {
        LocalSetupHTTPStub.installedModels = []
        let posted = expectation(
            forNotification: .usageMemoryLocalModelSetupCompleted,
            object: nil,
            handler: nil
        )

        let model = makeModel()
        await model.detect()
        await model.startSetup(includeVision: false)

        XCTAssertEqual(model.state, .done)
        await fulfillment(of: [posted], timeout: 2)
    }
}

// MARK: - Ollama HTTP stub

/// `URLProtocol` answering Ollama's `/api/tags` and `/api/pull` endpoints from
/// scripted state, mirroring `MemoryActivationHTTPStub`'s lock pattern.
///
/// `/api/tags` serves `installedModels` (or refuses the connection when
/// `tagsFails`). `/api/pull` records the requested model name in order, streams
/// the scripted NDJSON lines (default: a minimal successful pull), and — when
/// the script succeeds — adds the model to `installedModels` so the model's
/// verification pass sees it served.
private final class LocalSetupHTTPStub: URLProtocol {
    private static let lock = NSLock()
    // Lock-guarded below; `nonisolated(unsafe)` tells StrictConcurrency the
    // safety is hand-managed (every access goes through `lock`).
    nonisolated(unsafe) private static var _installedModels: [String] = []
    nonisolated(unsafe) private static var _tagsFails = false
    nonisolated(unsafe) private static var _pullScripts: [String: [String]] = [:]
    nonisolated(unsafe) private static var _pullRequests: [String] = []

    static var installedModels: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _installedModels }
        set { lock.lock(); _installedModels = newValue; lock.unlock() }
    }

    static var tagsFails: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _tagsFails }
        set { lock.lock(); _tagsFails = newValue; lock.unlock() }
    }

    static var pullScripts: [String: [String]] {
        get { lock.lock(); defer { lock.unlock() }; return _pullScripts }
        set { lock.lock(); _pullScripts = newValue; lock.unlock() }
    }

    static var pullRequests: [String] {
        lock.lock(); defer { lock.unlock() }
        return _pullRequests
    }

    static func reset() {
        lock.lock()
        _installedModels = []
        _tagsFails = false
        _pullScripts = [:]
        _pullRequests = []
        lock.unlock()
    }

    private static let defaultPullScript = [
        #"{"status":"pulling manifest"}"#,
        #"{"status":"pulling layer","digest":"sha256:layer","total":1000,"completed":1000}"#,
        #"{"status":"verifying sha256 digest"}"#,
        #"{"status":"success"}"#
    ]

    override static func canInit(with request: URLRequest) -> Bool {
        guard let path = request.url?.path else { return false }
        return path.hasSuffix("/api/tags") || path.hasSuffix("/api/pull")
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.hasSuffix("/api/tags") {
            serveTags(url: url)
        } else {
            servePull(url: url)
        }
    }

    override func stopLoading() {}

    private func serveTags(url: URL) {
        if Self.tagsFails {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let names = Self.installedModels
            .map { #"{"name":"\#($0)"}"# }
            .joined(separator: ",")
        respond(url: url, body: Data(#"{"models":[\#(names)]}"#.utf8))
    }

    private func servePull(url: URL) {
        let name = Self.requestedModelName(from: request) ?? "?"
        let script: [String]
        do {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            Self._pullRequests.append(name)
            script = Self._pullScripts[name] ?? Self.defaultPullScript
            if script.contains(where: { $0.contains(#""status":"success""#) }) {
                Self._installedModels.append(name)
            }
        }
        respond(url: url, body: Data((script.joined(separator: "\n") + "\n").utf8))
    }

    private func respond(url: URL, body: Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// `URLSession` hands `URLProtocol` the POST body as a stream, never as
    /// `httpBody` — drain it to recover `{"name": …}`.
    private static func requestedModelName(from request: URLRequest) -> String? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        struct PullRequestBody: Decodable { let name: String }
        return (try? JSONDecoder().decode(PullRequestBody.self, from: data))?.name
    }
}
