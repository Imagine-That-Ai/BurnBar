import Foundation
import Network
import os.log

// MARK: - Cast Discovery
//
// Bonjour browser for `_googlecast._tcp.local.` services. Resolves each
// discovered service to a host + port + TXT record then publishes
// `CastDevice` instances on the main actor. Designed for the wizard's
// "Discover" step — start when the wizard opens, stop when it closes.
//
// Why `NWBrowser` over the older `NetServiceBrowser`: NWBrowser surfaces
// resolution, TXT records, and IP changes as a unified stream; on macOS
// 14+ it's the supported path forward.

@MainActor
final class CastDiscovery {

    private static let log = Logger(subsystem: "com.openburnbar.app", category: "CastDiscovery")

    /// Closure called whenever the device list changes. The argument is
    /// the full deduplicated set, so views can do a straight assignment.
    private let onUpdate: ([CastDevice]) -> Void

    private var browser: NWBrowser?

    /// Internal cache: service name → resolved device. Devices arrive
    /// twice (browse "added" then resolve completes) — the cache lets us
    /// publish once both halves are known.
    private var cache: [String: CastDevice] = [:]
    private var pendingResolutions: [String: NWEndpoint] = [:]
    private var resolverTasks: [String: Task<Void, Never>] = [:]

    init(onUpdate: @escaping ([CastDevice]) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        stop()
        // `bonjourWithTXTRecord` (vs plain `bonjour`) is the magic incantation
        // that makes the browser actually surface TXT metadata in
        // `result.metadata`. With plain `.bonjour(...)` the metadata
        // arrives as `.none` and we end up showing the raw service name.
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: "_googlecast._tcp.",
            domain: "local."
        )
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            Task { @MainActor in
                self.applyChanges(results: results, changes: changes)
            }
        }
        browser.stateUpdateHandler = { state in
            // We don't surface intermediate states upward; if browsing
            // fails we'll just publish an empty list which the wizard
            // surfaces as "no devices yet".
            _ = state
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for task in resolverTasks.values { task.cancel() }
        resolverTasks.removeAll()
        pendingResolutions.removeAll()
        cache.removeAll()
    }

    // MARK: - Internal

    private func applyChanges(
        results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>
    ) {
        for change in changes {
            switch change {
            case .added(let result), .changed(_, let result, _):
                resolve(result)
            case .removed(let result):
                if let serviceName = result.serviceName {
                    cache.removeValue(forKey: serviceName)
                    pendingResolutions.removeValue(forKey: serviceName)
                    resolverTasks[serviceName]?.cancel()
                    resolverTasks.removeValue(forKey: serviceName)
                }
            default:
                break
            }
        }
        // Re-publish current cache regardless of change kind.
        publish()
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard let serviceName = result.serviceName else { return }

        // Capture TXT metadata up front — the browser hands us the bonjour
        // metadata even before we open a connection.
        var friendlyName = serviceName
        var model = "Cast Device"
        var identifier = serviceName
        var capabilityFlags: Int = 0  // `ca` field — Cast capability bitmask
        if case let .bonjour(record) = result.metadata {
            // NWTXTRecord exposes entries via getEntry(for:); the
            // subscript form (`record["fn"]`) is on `Dictionary` but
            // not `NWTXTRecord` directly. We pull entries explicitly.
            if let fn = record.txtValue(for: "fn"), !fn.isEmpty {
                friendlyName = fn
            }
            if let md = record.txtValue(for: "md"), !md.isEmpty {
                model = md
            }
            if let id = record.txtValue(for: "id"), !id.isEmpty {
                identifier = id
            }
            if let ca = record.txtValue(for: "ca"), let parsed = Int(ca) {
                capabilityFlags = parsed
            }
        }

        // Log every discovery for debugging. Cast devices return TXT
        // records with friendly name in `fn`, model in `md`. If we see
        // raw service names in the picker, this log will reveal whether
        // the TXT records weren't carrying that info.
        Self.log.info("cast.discover serviceName=\(serviceName, privacy: .public) fn=\(friendlyName, privacy: .public) md=\(model, privacy: .public) ca=\(capabilityFlags, privacy: .public)")

        // We **don't** filter at the discovery layer anymore — that
        // turned out to drop legit Nest Hubs whose `ca` field arrived
        // late or missing. The wizard UI now shows every device, but
        // marks audio-only devices with a "(speaker — won't display)"
        // hint so users don't pick them.
        let supportsDisplay = inferSupportsDisplay(
            capabilityFlags: capabilityFlags,
            model: model,
            serviceName: serviceName
        )

        // Open a transient NWConnection just long enough to learn the
        // resolved host:port, then cancel. NWBrowser doesn't directly
        // surface IPs without a connection on macOS 14, so this is the
        // sanctioned path.
        resolverTasks[serviceName]?.cancel()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            await withCheckedContinuation { continuation in
                var resumed = false
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let endpoint = connection.currentPath?.remoteEndpoint,
                           case let .hostPort(host, port) = endpoint {
                            Task { @MainActor in
                                self.recordResolved(
                                    serviceName: serviceName,
                                    friendlyName: friendlyName,
                                    model: model,
                                    identifier: identifier,
                                    host: hostString(host),
                                    port: Int(port.rawValue),
                                    supportsDisplay: supportsDisplay
                                )
                            }
                        }
                        connection.cancel()
                        if !resumed { resumed = true; continuation.resume() }
                    case .failed, .cancelled:
                        if !resumed { resumed = true; continuation.resume() }
                    default:
                        break
                    }
                }
                connection.start(queue: .main)
            }
        }
        resolverTasks[serviceName] = task
    }

    private func recordResolved(
        serviceName: String,
        friendlyName: String,
        model: String,
        identifier: String,
        host: String,
        port: Int,
        supportsDisplay: Bool
    ) {
        cache[serviceName] = CastDevice(
            serviceName: serviceName,
            friendlyName: friendlyName,
            host: host,
            port: port,
            model: model,
            identifier: identifier,
            supportsDisplay: supportsDisplay
        )
        publish()
    }

    private func publish() {
        // Sort: display-capable devices first, then audio-only, both
        // alphabetical inside their bucket.
        let sorted = cache.values.sorted { lhs, rhs in
            if lhs.supportsDisplay != rhs.supportsDisplay {
                return lhs.supportsDisplay && !rhs.supportsDisplay
            }
            return lhs.friendlyName.localizedCaseInsensitiveCompare(rhs.friendlyName) == .orderedAscending
        }
        onUpdate(Array(sorted))
    }
}

// MARK: - Helpers

private func hostString(_ host: NWEndpoint.Host) -> String {
    switch host {
    case .name(let name, _): return name
    case .ipv4(let v4):      return v4.debugDescription.split(separator: "%").first.map(String.init) ?? v4.debugDescription
    case .ipv6(let v6):      return v6.debugDescription
    @unknown default:        return "\(host)"
    }
}

private extension NWBrowser.Result {
    var serviceName: String? {
        if case let .service(name, _, _, _) = endpoint { return name }
        return nil
    }
}

private extension NWTXTRecord {
    /// Decode a single TXT record entry as UTF-8 if possible. The
    /// underlying API hands back an `Entry` enum (`.string` / `.data`
    /// / `.empty` / `.none`); both the string and data paths can hold
    /// useful values, so we coerce to UTF-8 from either.
    func txtValue(for key: String) -> String? {
        switch getEntry(for: key) {
        case .some(.string(let value)):
            return value
        case .some(.data(let data)):
            return String(data: data, encoding: .utf8)
        case .some(.empty), .some(.none), .none:
            return nil
        @unknown default:
            return nil
        }
    }
}

/// Best-guess "this device can render webpages" check. We only mark a
/// device as `supportsDisplay = false` if we're confident it's
/// audio-only — when in doubt we let the user try, because false
/// negatives (Nest Hubs marked as speakers) are way worse than a single
/// `NOT_FOUND` retry on a Mini.
///
/// The signals, in priority order:
///   1. `ca` bitmask bit 0x04 = video_out → definitively a display.
///   2. Service name / model containing "hub", "tv", "display",
///      "chromecast" → display.
///   3. Service name / model containing "mini", "audio", "speaker",
///      "home-max" → audio-only.
///   4. Otherwise, default to allowing the cast attempt.
private func inferSupportsDisplay(
    capabilityFlags: Int,
    model: String,
    serviceName: String
) -> Bool {
    if (capabilityFlags & 0x04) != 0 { return true }

    let combined = "\(model) \(serviceName)".lowercased()
    if combined.contains("hub") || combined.contains("tv")
        || combined.contains("display") || combined.contains("chromecast") {
        return true
    }
    if combined.contains("mini") || combined.contains("audio")
        || combined.contains("speaker") || combined.contains("home-max") {
        return false
    }
    return true  // unknown — let the user try
}
