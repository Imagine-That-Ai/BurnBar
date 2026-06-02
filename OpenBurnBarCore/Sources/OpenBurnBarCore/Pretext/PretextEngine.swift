import Foundation
import WebKit
import OSLog

// MARK: - Pretext Engine
//
// Single offscreen `WKWebView` running our bundled `Pretext` shell. Lives in
// the shared `OpenBurnBarCore` package so iOS, iPadOS, and macOS hosts share
// the exact same engine + bundled JS. Resources resolve via `Bundle.module`,
// which Swift Package Manager wires automatically for `.process("Resources")`
// targets.
//
// Lifecycle:
//   1. The shared instance is created the first time anyone calls into the
//      engine. Construction is cheap — just a `WKWebView`. We never display
//      it.
//   2. `start()` loads the bundled shell. Until the JS posts back a
//      `{ id: 0, ok: true, value: { ready: true } }` heartbeat, calls block
//      on the `readyContinuations` queue.
//   3. Every Swift call → JSON-encodes the request, awaits a Continuation
//      keyed by the next request ID, then resolves when the JS posts back.
//
// All public state is `@MainActor`-isolated. WKWebView itself must be touched
// on the main actor, and serializing through MainActor keeps continuations
// and handle bookkeeping simple.

@MainActor
public final class PretextEngine: NSObject {

    // MARK: Shared

    public static let shared = PretextEngine()

    // MARK: State

    private let logger = Logger(subsystem: "com.openburnbar.core", category: "PretextEngine")

    private static let readinessTimeoutNanoseconds: UInt64 = 5_000_000_000
    private static let bridgeCallTimeoutNanoseconds: UInt64 = 5_000_000_000
    private static let maxPreparedCacheEntries = 128
    private static let maxPreparedTextCharacters = 32_768
    private static let maxFontCharacters = 256
    private static let maxRichInlineItems = 512
    private static let maxRichInlineTextCharacters = 32_768
    private static let maxLayoutWidth: CGFloat = 100_000
    private static let maxLineHeight: CGFloat = 2_000

    private var webView: WKWebView!
    private var nextRequestID: Int = 1
    private var nextReadyWaiterID: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<Any, Error>] = [:]
    private var pendingRequestTimeouts: [Int: Task<Void, Never>] = [:]
    private var readyContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var readyTimeouts: [Int: Task<Void, Never>] = [:]
    private var isReady: Bool = false
    private var didStartLoad: Bool = false
    private var startupError: PretextError?

    /// Cache of `PreparedText` handles keyed by their input contract.
    private var preparedCache: [PreparedKey: PretextHandle] = [:]
    private var preparedSegmentsCache: [PreparedKey: PretextHandle] = [:]
    private var preparedCacheOrder: [PreparedKey] = []
    private var preparedSegmentsCacheOrder: [PreparedKey] = []

    private struct PreparedKey: Hashable {
        let text: String
        let font: String
        let options: PretextOptions
    }

    // MARK: Init

    private override init() {
        super.init()
        configureWebView()
    }

    private func configureWebView() {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.userContentController.add(BridgeHandler(engine: self), name: "pretext")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        #if canImport(UIKit)
        view.isHidden = true
        #endif
        webView = view
    }

    // MARK: Start

    /// Kick off the shell load. Idempotent — safe to call from `App.init` or
    /// the first call site, whichever comes first.
    public func start() {
        guard !didStartLoad else { return }
        didStartLoad = true
        guard let resourceDir = bundleURL else {
            logger.error("Pretext resources missing from package bundle.")
            startupError = .engineUnavailable
            didStartLoad = false
            failReadyWaiters(.engineUnavailable)
            return
        }
        startupError = nil
        let indexURL = resourceDir.appendingPathComponent("index.html")
        webView.loadFileURL(indexURL, allowingReadAccessTo: resourceDir)
    }

    private var bundleURL: URL? {
        // SwiftPM's `.process("Resources")` rule flattens nested folders, so
        // `index.html` and `pretext.bundle.min.js` both land at the root of
        // `Bundle.module`. The HTML's `<script src="pretext.bundle.min.js">`
        // still resolves correctly because the two files end up in the same
        // directory — the bundle root — not because we ship a Pretext/
        // subfolder.
        //
        // We try a few candidate locations to stay resilient against future
        // SwiftPM behaviour or platform-specific bundle layouts:
        //   1. `Pretext/index.html` (in case `.copy` semantics return)
        //   2. `index.html` at the bundle root (current SwiftPM behaviour)
        //   3. `Pretext` folder reference
        if let html = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Pretext") {
            return html.deletingLastPathComponent()
        }
        if let html = Bundle.module.url(forResource: "index", withExtension: "html") {
            return html.deletingLastPathComponent()
        }
        if let folder = Bundle.module.url(forResource: "Pretext", withExtension: nil) {
            return folder
        }
        return nil
    }

    /// Block until the shell is fully loaded and Pretext is ready. Called
    /// implicitly by every public API; surfaces `PretextError.engineUnavailable`
    /// if the bundle resources are missing.
    private func awaitReady() async throws {
        if isReady { return }
        if let startupError { throw startupError }
        start()
        if let startupError { throw startupError }
        guard didStartLoad else { throw PretextError.engineUnavailable }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let waiterID = nextReadyWaiterID
            nextReadyWaiterID += 1
            readyContinuations[waiterID] = cont
            readyTimeouts[waiterID] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.readinessTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.timeoutReadyWaiter(waiterID)
            }
        }
    }

    // MARK: Public API

    /// Returns a cached `PretextHandle` for `(text, font, options)`. The
    /// underlying JS `PreparedText` is created exactly once per unique input.
    public func prepare(
        text: String,
        font: String,
        options: PretextOptions = .normal
    ) async throws -> PretextHandle {
        try validatePreparedInput(text: text, font: font, options: options)
        let key = PreparedKey(text: text, font: font, options: options)
        if let cached = preparedCache[key] {
            Self.markPreparedKeyRecentlyUsed(key, in: &preparedCacheOrder)
            return cached
        }
        let handle = try await callForHandle("prepare", params: [
            "text": text,
            "font": font,
            "options": optionsJSON(options)
        ])
        releaseEvictedPreparedHandles(Self.cachePreparedHandle(
            handle,
            key: key,
            cache: &preparedCache,
            order: &preparedCacheOrder
        ))
        return handle
    }

    /// `prepareWithSegments` — richer prep used by manual line layout.
    public func prepareWithSegments(
        text: String,
        font: String,
        options: PretextOptions = .normal
    ) async throws -> PretextHandle {
        try validatePreparedInput(text: text, font: font, options: options)
        let key = PreparedKey(text: text, font: font, options: options)
        if let cached = preparedSegmentsCache[key] {
            Self.markPreparedKeyRecentlyUsed(key, in: &preparedSegmentsCacheOrder)
            return cached
        }
        let handle = try await callForHandle("prepareWithSegments", params: [
            "text": text,
            "font": font,
            "options": optionsJSON(options)
        ])
        releaseEvictedPreparedHandles(Self.cachePreparedHandle(
            handle,
            key: key,
            cache: &preparedSegmentsCache,
            order: &preparedSegmentsCacheOrder
        ))
        return handle
    }

    /// `layout(prepared, maxWidth, lineHeight)` — paragraph height + lineCount.
    public func layout(
        handle: PretextHandle,
        maxWidth: CGFloat,
        lineHeight: CGFloat
    ) async throws -> PretextLayoutResult {
        try validateLayout(maxWidth: maxWidth, lineHeight: lineHeight)
        let value = try await call("layout", params: [
            "handle": handle.id,
            "maxWidth": Double(maxWidth),
            "lineHeight": Double(lineHeight)
        ])
        guard let dict = value as? [String: Any],
              let height = (dict["height"] as? NSNumber)?.doubleValue,
              let lineCount = (dict["lineCount"] as? NSNumber)?.intValue else {
            throw PretextError.invalidResponse
        }
        return PretextLayoutResult(height: CGFloat(height), lineCount: lineCount)
    }

    /// `layoutWithLines(prepared, maxWidth, lineHeight)`.
    public func layoutWithLines(
        handle: PretextHandle,
        maxWidth: CGFloat,
        lineHeight: CGFloat
    ) async throws -> PretextLinesResult {
        try validateLayout(maxWidth: maxWidth, lineHeight: lineHeight)
        let value = try await call("layoutWithLines", params: [
            "handle": handle.id,
            "maxWidth": Double(maxWidth),
            "lineHeight": Double(lineHeight)
        ])
        guard let dict = value as? [String: Any],
              let height = (dict["height"] as? NSNumber)?.doubleValue,
              let lineCount = (dict["lineCount"] as? NSNumber)?.intValue,
              let rawLines = dict["lines"] as? [[String: Any]] else {
            throw PretextError.invalidResponse
        }
        let lines = rawLines.compactMap { entry -> PretextLine? in
            guard let text = entry["text"] as? String,
                  let width = (entry["width"] as? NSNumber)?.doubleValue else { return nil }
            return PretextLine(text: text, width: CGFloat(width))
        }
        return PretextLinesResult(height: CGFloat(height), lineCount: lineCount, lines: lines)
    }

    /// `measureLineStats(prepared, maxWidth)`.
    public func measureLineStats(
        handle: PretextHandle,
        maxWidth: CGFloat
    ) async throws -> PretextLineStats {
        try validateWidth(maxWidth)
        let value = try await call("measureLineStats", params: [
            "handle": handle.id,
            "maxWidth": Double(maxWidth)
        ])
        guard let dict = value as? [String: Any],
              let lineCount = (dict["lineCount"] as? NSNumber)?.intValue,
              let maxW = (dict["maxLineWidth"] as? NSNumber)?.doubleValue else {
            throw PretextError.invalidResponse
        }
        return PretextLineStats(lineCount: lineCount, maxLineWidth: CGFloat(maxW))
    }

    /// `measureNaturalWidth(prepared)` — widest forced line when width itself
    /// isn't causing wraps.
    public func measureNaturalWidth(handle: PretextHandle) async throws -> CGFloat {
        let value = try await call("measureNaturalWidth", params: [
            "handle": handle.id
        ])
        guard let dict = value as? [String: Any],
              let width = (dict["width"] as? NSNumber)?.doubleValue else {
            throw PretextError.invalidResponse
        }
        return CGFloat(width)
    }

    /// `prepareRichInline(items)` for mixed-font inline layout.
    public func prepareRichInline(items: [PretextRichInlineItem]) async throws -> PretextRichHandle {
        try validateRichInlineItems(items)
        let payload = items.map { item -> [String: Any] in
            var entry: [String: Any] = [
                "text": item.text,
                "font": item.font,
                "extraWidth": Double(item.extraWidth)
            ]
            if item.breakNever { entry["break"] = "never" }
            return entry
        }
        let value = try await call("prepareRichInline", params: ["items": payload])
        guard let dict = value as? [String: Any],
              let id = (dict["handle"] as? NSNumber)?.intValue else {
            throw PretextError.invalidResponse
        }
        return PretextRichHandle(id: id)
    }

    /// Lay a prepared rich-inline run out at `maxWidth`. Returns one
    /// `PretextRichLine` per wrapped line. Callers map fragment `itemIndex`
    /// back to their own font/color metadata.
    public func layoutRichInline(
        handle: PretextRichHandle,
        maxWidth: CGFloat
    ) async throws -> [PretextRichLine] {
        try validateWidth(maxWidth)
        let value = try await call("layoutRichInline", params: [
            "handle": handle.id,
            "maxWidth": Double(maxWidth)
        ])
        guard let dict = value as? [String: Any],
              let rawLines = dict["lines"] as? [[String: Any]] else {
            throw PretextError.invalidResponse
        }
        return rawLines.compactMap { line -> PretextRichLine? in
            guard let width = (line["width"] as? NSNumber)?.doubleValue,
                  let frags = line["fragments"] as? [[String: Any]] else { return nil }
            let fragments = frags.compactMap { f -> PretextRichFragment? in
                guard let text = f["text"] as? String,
                      let idx = (f["itemIndex"] as? NSNumber)?.intValue else { return nil }
                let gap = (f["gapBefore"] as? NSNumber)?.doubleValue ?? 0
                return PretextRichFragment(text: text, itemIndex: idx, gapBefore: CGFloat(gap))
            }
            return PretextRichLine(width: CGFloat(width), fragments: fragments)
        }
    }

    /// Free the JS-side handle. Cached prepares keep theirs alive — only
    /// uncached one-off prepares need explicit release.
    public func release(handle: PretextHandle) async {
        _ = try? await call("releaseHandle", params: ["handle": handle.id])
    }

    public func release(handle: PretextRichHandle) async {
        _ = try? await call("releaseHandle", params: ["handle": handle.id])
    }

    // MARK: Convenience helpers

    /// Find the tightest container width (within `[lower, upper]`) that keeps
    /// the rendered line count ≤ `targetLines`. Useful for shrink-wrap and
    /// balanced layouts.
    public func shrinkWrapWidth(
        handle: PretextHandle,
        upper: CGFloat,
        lower: CGFloat = 16,
        targetLines: Int
    ) async throws -> CGFloat {
        var lo = max(lower, 1)
        var hi = max(upper, lo + 1)
        let upperStats = try await measureLineStats(handle: handle, maxWidth: hi)
        guard upperStats.lineCount <= targetLines else { return hi }
        for _ in 0..<24 {
            if hi - lo <= 1 { break }
            let mid = (lo + hi) / 2
            let stats = try await measureLineStats(handle: handle, maxWidth: mid)
            if stats.lineCount <= targetLines {
                hi = mid
            } else {
                lo = mid
            }
        }
        return hi
    }

    // MARK: Internal — bridge plumbing

    fileprivate func handleBridgeMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let id = (dict["id"] as? NSNumber)?.intValue else { return }

        // Readiness heartbeat (id == 0).
        if id == 0 {
            isReady = true
            startupError = nil
            resumeReadyWaiters()
            return
        }

        guard let cont = pendingRequests.removeValue(forKey: id) else { return }
        pendingRequestTimeouts.removeValue(forKey: id)?.cancel()
        let okFlag = (dict["ok"] as? NSNumber)?.boolValue ?? false
        if okFlag {
            cont.resume(returning: dict["value"] ?? [String: Any]())
        } else {
            let msg = (dict["error"] as? String) ?? "unknown"
            cont.resume(throwing: PretextError.bridgeError(msg))
        }
    }

    private func call(_ method: String, params: [String: Any]) async throws -> Any {
        try await awaitReady()
        let id = nextRequestID
        nextRequestID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let jsonString = String(data: json, encoding: .utf8) else {
            throw PretextError.invalidResponse
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            pendingRequests[id] = cont
            pendingRequestTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.bridgeCallTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.timeoutPendingRequest(id)
            }
            let escaped = jsonString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            let script = "window.__pretextDispatch && window.__pretextDispatch(\"\(escaped)\");"
            webView.evaluateJavaScript(script) { [weak self] _, error in
                if let error = error {
                    Task { @MainActor [weak self] in
                        self?.failPendingRequest(id, with: .bridgeError(error.localizedDescription))
                    }
                }
            }
        }
    }

    private func callForHandle(_ method: String, params: [String: Any]) async throws -> PretextHandle {
        let value = try await call(method, params: params)
        guard let dict = value as? [String: Any],
              let id = (dict["handle"] as? NSNumber)?.intValue else {
            throw PretextError.invalidResponse
        }
        return PretextHandle(id: id)
    }

    private func optionsJSON(_ options: PretextOptions) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let ws = options.whiteSpace { dict["whiteSpace"] = ws.rawValue }
        if let wb = options.wordBreak { dict["wordBreak"] = wb.rawValue }
        if let ls = options.letterSpacing { dict["letterSpacing"] = ls }
        return dict
    }

    private func validatePreparedInput(text: String, font: String, options: PretextOptions) throws {
        guard !text.isEmpty else { throw PretextError.inputRejected("text is empty") }
        guard text.count <= Self.maxPreparedTextCharacters else {
            throw PretextError.inputRejected("text exceeds \(Self.maxPreparedTextCharacters) characters")
        }
        guard !font.isEmpty, font.count <= Self.maxFontCharacters else {
            throw PretextError.inputRejected("font descriptor is invalid")
        }
        if let letterSpacing = options.letterSpacing,
           (!letterSpacing.isFinite || abs(letterSpacing) > 256) {
            throw PretextError.inputRejected("letter spacing is invalid")
        }
    }

    private func validateRichInlineItems(_ items: [PretextRichInlineItem]) throws {
        guard !items.isEmpty else { throw PretextError.inputRejected("rich inline input is empty") }
        guard items.count <= Self.maxRichInlineItems else {
            throw PretextError.inputRejected("rich inline item count exceeds \(Self.maxRichInlineItems)")
        }
        let totalText = items.reduce(0) { $0 + $1.text.count }
        guard totalText <= Self.maxRichInlineTextCharacters else {
            throw PretextError.inputRejected("rich inline text exceeds \(Self.maxRichInlineTextCharacters) characters")
        }
        for item in items {
            guard !item.font.isEmpty, item.font.count <= Self.maxFontCharacters else {
                throw PretextError.inputRejected("font descriptor is invalid")
            }
            guard item.extraWidth.isFinite, item.extraWidth >= 0, item.extraWidth <= Self.maxLayoutWidth else {
                throw PretextError.inputRejected("extra width is invalid")
            }
        }
    }

    private func validateLayout(maxWidth: CGFloat, lineHeight: CGFloat) throws {
        try validateWidth(maxWidth)
        guard lineHeight.isFinite, lineHeight > 0, lineHeight <= Self.maxLineHeight else {
            throw PretextError.inputRejected("line height is invalid")
        }
    }

    private func validateWidth(_ maxWidth: CGFloat) throws {
        guard maxWidth.isFinite, maxWidth > 0, maxWidth <= Self.maxLayoutWidth else {
            throw PretextError.inputRejected("max width is invalid")
        }
    }

    private static func markPreparedKeyRecentlyUsed(_ key: PreparedKey, in order: inout [PreparedKey]) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private static func cachePreparedHandle(
        _ handle: PretextHandle,
        key: PreparedKey,
        cache: inout [PreparedKey: PretextHandle],
        order: inout [PreparedKey]
    ) -> [PretextHandle] {
        var evictedHandles: [PretextHandle] = []
        cache[key] = handle
        markPreparedKeyRecentlyUsed(key, in: &order)
        while order.count > Self.maxPreparedCacheEntries, let evictedKey = order.first {
            order.removeFirst()
            if let evicted = cache.removeValue(forKey: evictedKey) {
                evictedHandles.append(evicted)
            }
        }
        return evictedHandles
    }

    private func releaseEvictedPreparedHandles(_ handles: [PretextHandle]) {
        for handle in handles {
            Task { @MainActor [weak self] in
                await self?.release(handle: handle)
            }
        }
    }

    private func resumeReadyWaiters() {
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for task in readyTimeouts.values { task.cancel() }
        readyTimeouts.removeAll()
        for (_, cont) in waiters { cont.resume() }
    }

    private func failReadyWaiters(_ error: PretextError) {
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for task in readyTimeouts.values { task.cancel() }
        readyTimeouts.removeAll()
        for (_, cont) in waiters {
            cont.resume(throwing: error)
        }
    }

    private func failPendingRequests(_ error: PretextError) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for task in pendingRequestTimeouts.values { task.cancel() }
        pendingRequestTimeouts.removeAll()
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
    }

    private func failPendingRequest(_ id: Int, with error: PretextError) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pendingRequestTimeouts.removeValue(forKey: id)?.cancel()
        pending.resume(throwing: error)
    }

    private func timeoutPendingRequest(_ id: Int) {
        failPendingRequest(id, with: .timeout)
    }

    private func timeoutReadyWaiter(_ id: Int) {
        guard let waiter = readyContinuations.removeValue(forKey: id) else { return }
        readyTimeouts.removeValue(forKey: id)?.cancel()
        waiter.resume(throwing: PretextError.timeout)
    }
}

// MARK: - Navigation Delegate

extension PretextEngine: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logger.error("Pretext shell failed to load: \(error.localizedDescription)")
        startupError = .engineUnavailable
        isReady = false
        didStartLoad = false
        failPendingRequests(.bridgeError(error.localizedDescription))
        failReadyWaiters(.engineUnavailable)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
}

// MARK: - Bridge Handler
//
// Lives on the WKWebView's userContentController. We keep a separate object
// (rather than making `PretextEngine` itself the handler) so the engine can
// stay `@MainActor` while the WKScriptMessageHandler protocol stays cleanly
// satisfied. Strong reference to the engine is fine — both have app lifetime.

private final class BridgeHandler: NSObject, WKScriptMessageHandler {
    private let engine: PretextEngine

    init(engine: PretextEngine) {
        self.engine = engine
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body
        Task { @MainActor in
            engine.handleBridgeMessage(body)
        }
    }
}
