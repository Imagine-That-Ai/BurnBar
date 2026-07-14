import Foundation

// MARK: - Keyboard → App Inbox

/// A hand-off queue for snippets created inside the iOS keyboard extension.
///
/// The keyboard cannot reach Firestore or the encrypted cloud vault, so when a
/// user adds a snippet from the keyboard we (1) merge it straight into the shared
/// snapshot — so it is usable immediately on the next keystroke — and (2) drop it
/// into this inbox. The main app drains the inbox on launch / foreground and
/// pushes the additions through its normal `upsert` + cloud-sync path.
public enum TextExpansionInbox {
    public static let inboxFileName = "text-expansion-inbox.json"

    public static func inboxURL(
        appGroupIdentifier: String = TextExpansionSnapshotStore.appGroupIdentifier
    ) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(inboxFileName)
    }

    public static func read(from url: URL) -> [TextExpansionSnippet] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TextExpansionSnippet].self, from: data)) ?? []
    }

    public static func write(_ snippets: [TextExpansionSnippet], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snippets)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    /// Queues a snippet for the app to ingest. De-duplicates by id (last write wins)
    /// so re-adding before a drain does not create duplicate entries.
    public static func append(
        _ snippet: TextExpansionSnippet,
        appGroupIdentifier: String = TextExpansionSnapshotStore.appGroupIdentifier
    ) throws {
        guard let url = inboxURL(appGroupIdentifier: appGroupIdentifier) else {
            throw TextExpansionInboxError.appGroupUnavailable
        }
        var pending = read(from: url).filter { $0.id != snippet.id }
        pending.append(snippet)
        try write(pending, to: url)
    }

    public static func hasPending(
        appGroupIdentifier: String = TextExpansionSnapshotStore.appGroupIdentifier
    ) -> Bool {
        guard let url = inboxURL(appGroupIdentifier: appGroupIdentifier) else { return false }
        return read(from: url).isEmpty == false
    }

    /// Returns all queued snippets and clears the inbox in one step.
    @discardableResult
    public static func drain(
        appGroupIdentifier: String = TextExpansionSnapshotStore.appGroupIdentifier
    ) -> [TextExpansionSnippet] {
        guard let url = inboxURL(appGroupIdentifier: appGroupIdentifier) else { return [] }
        let pending = read(from: url)
        guard pending.isEmpty == false else { return [] }
        try? write([], to: url)
        return pending
    }
}

public enum TextExpansionInboxError: LocalizedError, Equatable {
    case appGroupUnavailable

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "Shared storage is unavailable. Open OpenBurnBar once to finish setup."
        }
    }
}

// MARK: - Keyboard Composer

/// Self-contained "add a snippet from the keyboard" flow, shared so it can be unit
/// tested independently of the keyboard UI. It validates the trigger, guards
/// against duplicate triggers already present in the snapshot, merges the new
/// snippet into the shared snapshot (instant availability), and queues it in the
/// inbox for the app to sync.
public enum TextExpansionKeyboardComposer {
    public enum ComposeError: LocalizedError, Equatable {
        case invalidTrigger(String)
        case emptyBody
        case duplicateTrigger
        case appGroupUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidTrigger(let message): return message
            case .emptyBody: return "Add the text this snippet should insert."
            case .duplicateTrigger: return "That trigger already exists."
            case .appGroupUnavailable:
                return "Shared storage is unavailable. Open OpenBurnBar once to finish setup."
            }
        }
    }

    /// Builds a validated snippet from raw keyboard input without touching disk.
    /// Scoped to the iOS keyboard surface by default so a keyboard-born snippet is
    /// guaranteed to show up where it was created.
    public static func makeSnippet(
        rawTrigger: String,
        body: String,
        title: String? = nil,
        existing: [TextExpansionSnippet],
        sourceDeviceID: String? = nil,
        now: Date = Date()
    ) -> Result<TextExpansionSnippet, ComposeError> {
        let trigger = TextExpansionTrigger.canonicalName(rawTrigger)
        if let validationError = TextExpansionTrigger.validationError(for: trigger) {
            return .failure(.invalidTrigger(validationError))
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBody.isEmpty == false else { return .failure(.emptyBody) }

        let duplicate = existing.contains {
            $0.deletedAt == nil && $0.trigger == trigger
        }
        guard duplicate == false else { return .failure(.duplicateTrigger) }

        let resolvedTitle: String = {
            if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trigger
        }()

        let snippet = TextExpansionSnippet(
            title: resolvedTitle,
            trigger: trigger,
            body: trimmedBody,
            mode: .staticText,
            isEnabled: true,
            scope: TextExpansionScope(surfaces: TextExpansionSurface.allCases),
            createdAt: now,
            updatedAt: now,
            sourceDeviceID: sourceDeviceID
        )
        return .success(snippet)
    }

    /// Persists a keyboard-created snippet: merges it into the shared snapshot and
    /// queues it in the inbox. Returns the stored snippet on success.
    @discardableResult
    public static func add(
        rawTrigger: String,
        body: String,
        title: String? = nil,
        sourceDeviceID: String? = nil,
        now: Date = Date(),
        appGroupIdentifier: String = TextExpansionSnapshotStore.appGroupIdentifier
    ) -> Result<TextExpansionSnippet, ComposeError> {
        guard let snapshotURL = TextExpansionSnapshotStore.snapshotURL(appGroupIdentifier: appGroupIdentifier) else {
            return .failure(.appGroupUnavailable)
        }

        let existing = (try? TextExpansionSnapshotStore.read(from: snapshotURL).snippets) ?? []
        let result = makeSnippet(
            rawTrigger: rawTrigger,
            body: body,
            title: title,
            existing: existing,
            sourceDeviceID: sourceDeviceID,
            now: now
        )
        guard case .success(let snippet) = result else { return result }

        var merged = existing.filter { $0.id != snippet.id }
        merged.append(snippet)
        let snapshot = TextExpansionSnapshot(snippets: merged)
        do {
            try TextExpansionSnapshotStore.write(snapshot, to: snapshotURL)
            try TextExpansionInbox.append(snippet, appGroupIdentifier: appGroupIdentifier)
        } catch {
            return .failure(.appGroupUnavailable)
        }
        return .success(snippet)
    }
}
