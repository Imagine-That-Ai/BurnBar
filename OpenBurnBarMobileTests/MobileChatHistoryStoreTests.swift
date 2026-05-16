import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class MobileChatHistoryStoreTests: XCTestCase {

    func testUpsertPersistsToLocalStore() throws {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)

        let thread = Self.makeThread(id: "t1", runtime: .pi, title: "Hello", messageCount: 2)
        store.upsert(thread)

        XCTAssertEqual(local.snapshot.threads.count, 1)
        XCTAssertEqual(local.snapshot.threads.first?.id, "t1")
        XCTAssertEqual(store.threads(for: .pi).count, 1)
    }

    func testThreadsAreFilteredByRuntime() {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)

        store.upsert(Self.makeThread(id: "pi-1", runtime: .pi, title: "Pi chat"))
        store.upsert(Self.makeThread(id: "h-1", runtime: .hermes, title: "Hermes chat"))

        XCTAssertEqual(store.threads(for: .pi).map(\.id), ["pi-1"])
        XCTAssertEqual(store.threads(for: .hermes).map(\.id), ["h-1"])
    }

    func testLoadFromDiskRestoresThreads() throws {
        let local = InMemoryLocalStore()
        let seed = Self.makeThread(id: "seed", runtime: .hermes, title: "Restored")
        local.snapshot = MobileChatHistorySnapshot(threads: [seed], tombstones: [:])

        let store = MobileChatHistoryStore(local: local, cloud: nil)
        store.loadFromDiskIfNeeded()

        XCTAssertEqual(store.threads.map(\.id), ["seed"])
    }

    func testTombstonedThreadIsHiddenAfterRestore() {
        let local = InMemoryLocalStore()
        let thread = Self.makeThread(id: "dead", runtime: .pi, title: "Goodbye")
        local.snapshot = MobileChatHistorySnapshot(
            threads: [thread],
            tombstones: ["dead": Date()]
        )

        let store = MobileChatHistoryStore(local: local, cloud: nil)
        store.loadFromDiskIfNeeded()

        XCTAssertTrue(store.threads.isEmpty, "Tombstoned threads must not be visible after disk restore")
    }

    func testUpsertReplacesExistingThread() {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)

        var thread = Self.makeThread(id: "t1", runtime: .pi, title: "Original")
        store.upsert(thread)
        thread.title = "Edited"
        thread.preview = "Now updated"
        store.upsert(thread)

        XCTAssertEqual(store.threads(for: .pi).count, 1)
        XCTAssertEqual(store.threads(for: .pi).first?.title, "Edited")
    }

    func testDeleteRecordsTombstoneAndRemovesThread() {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)
        store.upsert(Self.makeThread(id: "t1", runtime: .pi, title: "Bye"))

        store.delete(threadID: "t1")

        XCTAssertTrue(store.threads.isEmpty)
        XCTAssertTrue(local.snapshot.threads.isEmpty)
        XCTAssertNotNil(local.snapshot.tombstones["t1"], "Delete must write a tombstone for offline-safe sync")
    }

    func testUpsertAfterDeleteIsRefused() {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)
        store.upsert(Self.makeThread(id: "t1", runtime: .pi, title: "Once"))
        store.delete(threadID: "t1")

        // A late-arriving streaming callback tries to resurrect the thread.
        store.upsert(Self.makeThread(id: "t1", runtime: .pi, title: "Resurrection"))

        XCTAssertTrue(store.threads.isEmpty)
    }

    func testMergeKeepsNewestUpdatedAt() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let localThread = Self.makeThread(id: "shared", runtime: .pi, title: "Local copy", updatedAt: newer)
        let remoteThread = Self.makeThread(id: "shared", runtime: .pi, title: "Remote copy", updatedAt: older)

        let merged = MobileChatHistoryStore.merge(local: [localThread], remote: [remoteThread])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.title, "Local copy")
    }

    func testRefreshFromCloudPushesLocalOnlyThreads() async {
        let local = InMemoryLocalStore()
        let cloud = MockCloud()
        let store = MobileChatHistoryStore(local: local, cloud: cloud)
        store.upsert(Self.makeThread(id: "local-only", runtime: .pi, title: "Created offline"))
        XCTAssertTrue(cloud.upserts.isEmpty, "Cloud is offline at upsert time")

        cloud.isAvailableValue = true
        await store.refreshFromCloud()
        // The mirror is scheduled; wait one tick for the immediate write.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(cloud.upserts.contains(where: { $0.id == "local-only" }),
                      "Local-only thread must be backfilled to Firestore once we're online")
    }

    func testRefreshFromCloudDoesNotResurrectTombstonedThread() async {
        let local = InMemoryLocalStore()
        let cloud = MockCloud()
        let thread = Self.makeThread(id: "dead", runtime: .pi, title: "Should stay dead")
        cloud.remote = [thread]
        cloud.isAvailableValue = true

        let store = MobileChatHistoryStore(local: local, cloud: cloud)
        store.upsert(thread)
        store.delete(threadID: "dead")

        await store.refreshFromCloud()

        XCTAssertFalse(store.threads.contains(where: { $0.id == "dead" }),
                       "Tombstoned threads must not come back from a stale remote snapshot")
    }

    func testSwitchPartitionIsolatesUsers() {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)
        store.switchPartition(to: "userA")
        store.upsert(Self.makeThread(id: "A1", runtime: .pi, title: "Alice"))
        XCTAssertEqual(store.threads.map(\.id), ["A1"])

        store.switchPartition(to: "userB")
        XCTAssertTrue(store.threads.isEmpty,
                      "Switching to a different uid must not surface the previous user's chats")

        store.upsert(Self.makeThread(id: "B1", runtime: .pi, title: "Bob"))

        store.switchPartition(to: "userA")
        XCTAssertEqual(store.threads.map(\.id), ["A1"],
                       "Switching back to Alice must restore her partition, not Bob's")
    }

    func testFileBackedStoreRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-chat-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = MobileChatFileLocalStore(directory: tempDir)
        writer.setActivePartition("alice")
        let thread = Self.makeThread(id: "rt", runtime: .pi, title: "Round-trip")
        try writer.save(MobileChatHistorySnapshot(threads: [thread], tombstones: ["zombie": Date()]))

        let reader = MobileChatFileLocalStore(directory: tempDir)
        reader.setActivePartition("alice")
        let restored = try reader.load()
        XCTAssertEqual(restored.threads.map(\.id), ["rt"])
        XCTAssertEqual(restored.tombstones.keys.sorted(), ["zombie"])
    }

    func testFileBackedStorePartitionsAreIsolated() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-chat-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MobileChatFileLocalStore(directory: tempDir)
        store.setActivePartition("alice")
        try store.save(MobileChatHistorySnapshot(threads: [Self.makeThread(id: "a", runtime: .pi, title: "Alice")]))
        store.setActivePartition("bob")
        let loaded = try store.load()
        XCTAssertTrue(loaded.threads.isEmpty, "Bob's partition must not see Alice's threads")
    }

    func testSanitizePartitionKeyStripsPathSeparators() {
        XCTAssertEqual(MobileChatFileLocalStore.sanitizePartitionKey("user/with/slashes"), "user-with-slashes")
        XCTAssertEqual(MobileChatFileLocalStore.sanitizePartitionKey(""), "local")
        XCTAssertEqual(MobileChatFileLocalStore.sanitizePartitionKey("../escape"), "escape")
    }

    func testAttachmentsRoundTripThroughLocalStore() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-chat-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let attachment = MobileChatAttachment(
            id: "att-1",
            kind: "image",
            displayName: "screenshot.png",
            mimeType: "image/png",
            byteSize: 12_345,
            workspaceRelativePath: "attachments/att-1-screenshot.png",
            thumbnailPNG: Data([0x89, 0x50, 0x4E, 0x47]),
            extractedTextPreview: nil
        )
        let usage = MobileChatTokenUsage(
            outputTokens: 256,
            totalTokens: 412,
            source: "providerUsage",
            providerGenerationDurationSeconds: 4.2,
            providerTotalDurationSeconds: 5.8,
            responseStartedAt: Date(timeIntervalSince1970: 1000),
            firstResponseChunkAt: Date(timeIntervalSince1970: 1001),
            responseCompletedAt: Date(timeIntervalSince1970: 1005)
        )
        let hermes = MobileChatHermesMetadata(
            requestedModelID: "gpt-5o",
            responseModelID: "gpt-5o-2026-04",
            toolCalls: [MobileChatToolCall(id: "tc-1", name: "web_search", status: "done")],
            usage: usage
        )
        let message = MobileChatMessage(
            id: "m-1",
            role: "assistant",
            text: "Here's the result.",
            timestamp: Date(timeIntervalSince1970: 1005),
            modelName: "gpt-5o-2026-04",
            isError: false,
            attachments: [attachment],
            hermes: hermes
        )
        let thread = MobileChatThread(
            id: "round-trip",
            runtime: AssistantRuntimeID.hermes.rawValue,
            title: "Attachment thread",
            preview: "Here's the result.",
            modelName: "gpt-5o",
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 1005),
            messages: [message]
        )

        let store = MobileChatFileLocalStore(directory: tempDir)
        store.setActivePartition("user-1")
        try store.save(MobileChatHistorySnapshot(threads: [thread]))

        let restored = try store.load().threads.first
        XCTAssertEqual(restored?.messages.first?.attachments.first?.id, "att-1")
        XCTAssertEqual(restored?.messages.first?.attachments.first?.thumbnailPNG?.count, 4)
        XCTAssertEqual(restored?.messages.first?.hermes?.toolCalls.first?.name, "web_search")
        XCTAssertEqual(restored?.messages.first?.hermes?.usage?.outputTokens, 256)
        XCTAssertEqual(restored?.messages.first?.hermes?.usage?.source, "providerUsage")
        XCTAssertEqual(restored?.messages.first?.hermes?.usage?.providerGenerationDurationSeconds, 4.2)
        XCTAssertEqual(restored?.messages.first?.hermes?.usage?.responseStartedAt?.timeIntervalSince1970, 1000)
    }

    func testCloudEncoderStripsThumbnailButPreservesAttachmentMetadata() {
        let attachment = MobileChatAttachment(
            id: "att-2",
            kind: "image",
            displayName: "photo.jpg",
            mimeType: "image/jpeg",
            byteSize: 250_000,
            workspaceRelativePath: "attachments/att-2-photo.jpg",
            thumbnailPNG: Data(repeating: 0xFF, count: 4_000),
            extractedTextPreview: nil
        )
        let usage = MobileChatTokenUsage(
            outputTokens: 100,
            totalTokens: 180,
            source: "providerUsage",
            providerGenerationDurationSeconds: 2.0,
            providerTotalDurationSeconds: 2.4,
            responseStartedAt: Date(timeIntervalSince1970: 2000),
            firstResponseChunkAt: nil,
            responseCompletedAt: Date(timeIntervalSince1970: 2002)
        )
        let message = MobileChatMessage(
            id: "m-2",
            role: "assistant",
            text: "ok",
            timestamp: Date(timeIntervalSince1970: 2002),
            attachments: [attachment],
            hermes: MobileChatHermesMetadata(
                requestedModelID: "claude-opus-4-8",
                responseModelID: "claude-opus-4-8",
                toolCalls: [],
                usage: usage
            )
        )

        let cloudDict = MobileChatFirestoreStore.encodeMessageForCloud(message)

        let attachmentDicts = cloudDict["attachments"] as? [[String: Any]]
        XCTAssertEqual(attachmentDicts?.first?["id"] as? String, "att-2")
        XCTAssertEqual(attachmentDicts?.first?["displayName"] as? String, "photo.jpg")
        XCTAssertNil(attachmentDicts?.first?["thumbnailPNG"], "Thumbnails must be stripped from cloud writes to stay under the 1 MiB doc limit")

        let hermesDict = cloudDict["hermes"] as? [String: Any]
        XCTAssertEqual(hermesDict?["requestedModelID"] as? String, "claude-opus-4-8")
        let usageDict = hermesDict?["usage"] as? [String: Any]
        XCTAssertEqual(usageDict?["outputTokens"] as? Int, 100)
        XCTAssertEqual(usageDict?["source"] as? String, "providerUsage")
        XCTAssertEqual(usageDict?["providerGenerationDurationSeconds"] as? Double, 2.0)
    }

    func testLegacyJSONWithoutAttachmentsLoadsCleanly() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-chat-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appendingPathComponent("mobile-chat-history-legacy.json")

        // Pre-attachments shape: messages have no `attachments` / `hermes` key.
        let legacyJSON = """
        [
          {
            "id": "legacy-thread",
            "runtime": "pi",
            "title": "Old chat",
            "preview": "Hi",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:01Z",
            "messages": [
              {
                "id": "m-old",
                "role": "user",
                "text": "Hi",
                "timestamp": "2026-01-01T00:00:00Z",
                "isError": false
              }
            ]
          }
        ]
        """
        try legacyJSON.data(using: .utf8)!.write(to: url, options: [.atomic])

        let store = MobileChatFileLocalStore(directory: tempDir)
        store.setActivePartition("legacy")
        let snapshot = try store.load()
        XCTAssertEqual(snapshot.threads.first?.messages.first?.attachments.count, 0)
        XCTAssertNil(snapshot.threads.first?.messages.first?.hermes)
    }

    // MARK: - Helpers

    private static func makeThread(
        id: String,
        runtime: AssistantRuntimeID,
        title: String,
        messageCount: Int = 1,
        updatedAt: Date = Date()
    ) -> MobileChatThread {
        let messages = (0..<messageCount).map { idx in
            MobileChatMessage(
                id: "\(id)-m\(idx)",
                role: idx == 0 ? "user" : "assistant",
                text: "Message \(idx)",
                timestamp: updatedAt
            )
        }
        return MobileChatThread(
            id: id,
            runtime: runtime.rawValue,
            title: title,
            preview: "Preview for \(title)",
            modelName: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            messages: messages
        )
    }
}

// MARK: - Test doubles

private final class InMemoryLocalStore: MobileChatLocalStoring {
    var partitions: [String: MobileChatHistorySnapshot] = [:]
    var activePartition: String = "local"

    var snapshot: MobileChatHistorySnapshot {
        get { partitions[activePartition] ?? MobileChatHistorySnapshot() }
        set { partitions[activePartition] = newValue }
    }

    func setActivePartition(_ key: String) {
        activePartition = key
    }

    func load() throws -> MobileChatHistorySnapshot {
        snapshot
    }

    func save(_ snapshot: MobileChatHistorySnapshot) throws {
        self.snapshot = snapshot
    }
}

@MainActor
private final class MockCloud: MobileChatCloudMirroring {
    var isAvailableValue: Bool = false
    var currentUserIDValue: String? = "test-uid"
    var remote: [MobileChatThread] = []
    var upserts: [MobileChatThread] = []
    var deletes: [String] = []

    var isAvailable: Bool { isAvailableValue }
    var currentUserID: String? { currentUserIDValue }

    func upsert(_ thread: MobileChatThread) async throws {
        upserts.append(thread)
        if let idx = remote.firstIndex(where: { $0.id == thread.id }) {
            remote[idx] = thread
        } else {
            remote.append(thread)
        }
    }

    func delete(threadID: String) async throws {
        deletes.append(threadID)
        remote.removeAll { $0.id == threadID }
    }

    func fetchAll() async throws -> [MobileChatThread] {
        remote
    }
}

// MARK: - Pi service persistence

@MainActor
final class PiServicePersistenceTests: XCTestCase {

    func testSendAppendsUserMessageAndPersists() {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)
        let service = PiService(defaults: makeDefaults(), history: store)

        service.send(prompt: "Hello Pi")

        XCTAssertEqual(service.messages.first?.role, .user)
        XCTAssertEqual(service.messages.first?.text, "Hello Pi")
        XCTAssertNotNil(service.currentThreadID)

        XCTAssertEqual(store.threads(for: .pi).count, 1)
        let saved = store.threads(for: .pi).first
        XCTAssertEqual(saved?.runtime, AssistantRuntimeID.pi.rawValue)
        XCTAssertTrue(saved?.messages.contains(where: { $0.role == "user" && $0.text == "Hello Pi" }) ?? false)
    }

    func testStartNewThreadClearsMessages() {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)
        let service = PiService(defaults: makeDefaults(), history: store)
        service.send(prompt: "First")
        let firstThreadID = service.currentThreadID

        service.startNewThread()

        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertNil(service.currentThreadID)
        XCTAssertEqual(store.threads(for: .pi).first?.id, firstThreadID)
    }

    func testLoadThreadRestoresMessages() {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)
        let service = PiService(defaults: makeDefaults(), history: store)
        service.send(prompt: "Persisted hi")
        let id = service.currentThreadID!
        service.startNewThread()
        XCTAssertTrue(service.messages.isEmpty)

        service.loadThread(id: id)

        XCTAssertEqual(service.currentThreadID, id)
        XCTAssertTrue(service.messages.contains(where: { $0.role == .user && $0.text == "Persisted hi" }))
    }

    func testDeleteThreadRemovesFromHistory() {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)
        let service = PiService(defaults: makeDefaults(), history: store)
        service.send(prompt: "Doomed")
        let id = service.currentThreadID!

        service.deleteThread(id: id)

        XCTAssertTrue(store.threads(for: .pi).isEmpty)
        XCTAssertNil(service.currentThreadID)
    }

    func testPiServiceClearSelectedModelRemovesPersistedPreference() {
        let defaults = makeDefaults()
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)
        let service = PiService(defaults: defaults, history: store)
        let option = HermesRuntimeModelOption(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5.5",
            displayName: "GPT-5.5"
        )

        service.selectModel(option)
        XCTAssertEqual(defaults.string(forKey: "pi.selectedModelID"), "gpt-5.5")

        service.clearSelectedModel()

        XCTAssertNil(service.selectedModelID)
        XCTAssertNil(defaults.string(forKey: "pi.selectedModelID"))
    }

    func testPiServiceFailsBeforeSendingWhenExplicitModelIsMissing() {
        let local = InMemoryLocalStore()
        let store = MobileChatHistoryStore(local: local, cloud: nil)
        let service = PiService(defaults: makeDefaults(), history: store)
        let stale = HermesRuntimeModelOption(
            providerID: "zai",
            providerName: "Z.AI",
            modelID: "glm-5.1",
            displayName: "GLM 5.1"
        )
        let available = HermesRuntimeModelOption(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5.5",
            displayName: "GPT-5.5"
        )

        service.modelOptions = [stale]
        service.selectModel(stale)
        service.modelOptions = [available]
        service.send(prompt: "Use the selected Pi model")

        XCTAssertFalse(service.isStreaming)
        XCTAssertTrue(service.lastError?.contains("Selected Pi model 'glm-5.1'") ?? false)
        XCTAssertTrue(service.messages.last?.isError ?? false)
        XCTAssertTrue(service.messages.last?.text.contains("Selected Pi model 'glm-5.1'") ?? false)
    }

    func testPiServiceMergeToolCallsAccumulatesArgumentsAcrossDeltas() {
        // OpenAI-compatible streaming sends a single tool call as a sequence
        // of `tool_calls` chunks — name first, then partial argument strings
        // tagged with the same `index`. Concatenate them and surface the
        // path/command/query/etc. as the pill's `detail`.
        var msg = PiChatMessage(role: .assistant, text: "")
        PiService.mergeToolCalls([
            ["index": 0, "id": "tc_1", "function": ["name": "read_file", "arguments": "{\"path\":\""]]
        ], into: &msg)
        PiService.mergeToolCalls([
            ["index": 0, "function": ["arguments": "docs/README.md\"}"]]
        ], into: &msg)

        XCTAssertEqual(msg.toolCalls.count, 1)
        XCTAssertEqual(msg.toolCalls.first?.id, "tc_1")
        XCTAssertEqual(msg.toolCalls.first?.name, "read_file")
        XCTAssertEqual(msg.toolCalls.first?.arguments, "{\"path\":\"docs/README.md\"}")
        XCTAssertEqual(msg.toolCalls.first?.status, "running")
        XCTAssertEqual(msg.toolCalls.first?.detail, "docs/README.md")
    }

    func testPiServiceSummarizeToolArgumentsPullsKnownKeys() {
        XCTAssertEqual(PiService.summarizeToolArguments(#"{"path":"/etc/hosts"}"#), "/etc/hosts")
        XCTAssertEqual(PiService.summarizeToolArguments(#"{"command":"ls -al"}"#), "ls -al")
        XCTAssertEqual(PiService.summarizeToolArguments(#"{"query":"timezone"}"#), "timezone")
        // Partial JSON fragment (mid-stream) — regex fallback should still
        // pull the path even before the JSON closes.
        XCTAssertEqual(
            PiService.summarizeToolArguments(#"{"path":"docs/README.md""#),
            "docs/README.md"
        )
        XCTAssertNil(PiService.summarizeToolArguments(""))
    }

    func testPiToolCallsRoundTripThroughChatHistory() throws {
        // Build a PiChatMessage with a tool call, persist via MobileChatMessage,
        // decode it back, and confirm the detail label survives.
        let original = PiChatMessage(
            role: .assistant,
            text: "Done.",
            toolCalls: [
                PiToolCall(
                    id: "tc_1",
                    name: "read_file",
                    status: "done",
                    arguments: #"{"path":"a.txt"}"#,
                    detail: "a.txt"
                )
            ]
        )
        let store = PiService.testHook_convertToStore(original)
        XCTAssertEqual(store.toolCalls.count, 1)
        XCTAssertEqual(store.toolCalls.first?.id, "tc_1")
        XCTAssertEqual(store.toolCalls.first?.name, "read_file")
        XCTAssertEqual(store.toolCalls.first?.detail, "a.txt")

        let restored = PiService.testHook_convertFromStore(store)
        XCTAssertEqual(restored.toolCalls.count, 1)
        XCTAssertEqual(restored.toolCalls.first?.detail, "a.txt")
        XCTAssertEqual(restored.toolCalls.first?.status, "done")
    }

    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "pi.persistence.\(UUID().uuidString)")!
        return suite
    }
}
