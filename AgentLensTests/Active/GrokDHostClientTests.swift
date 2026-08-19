import XCTest
@preconcurrency import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class GrokDHostClientTests: XCTestCase {
    private var session: URLSession!
    private let token = "test-token-do-not-print-xyz"

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokDStubURLProtocol.self]
        session = URLSession(configuration: config)
        GrokDStubURLProtocol.handler = nil
        GrokDStubURLProtocol.requests = []
    }

    override func tearDown() async throws {
        GrokDStubURLProtocol.handler = nil
        GrokDStubURLProtocol.requests = []
        session = nil
        try await super.tearDown()
    }

    func testBoxTitleCopy() {
        XCTAssertEqual(GrokDFeature.boxTitle(liveCount: 7), "Local D box (7 live agents)")
        XCTAssertFalse(GrokDFeature.isEnabled(defaults: UserDefaults(suiteName: "GrokDHostClientTests.flag")!))
    }

    func testConfigNeverUsesLocalhostAndRedactsToken() throws {
        let env = try makeActiveEnv(token: token, mode: "cursor")
        let config = try GrokDHostConfig.load(fromActiveEnv: env)
        XCTAssertEqual(config.loopbackHost, "127.0.0.1")
        XCTAssertEqual(config.shimPort, 1337)
        XCTAssertEqual(try config.apiURL("listAgents").absoluteString, "http://127.0.0.1:1337/api/listAgents")
        XCTAssertFalse(try config.apiURL("sendPrompt").absoluteString.contains("localhost"))
        XCTAssertFalse(config.guiIsLocalProfile)
        XCTAssertFalse(config.description.contains(token))
        XCTAssertFalse(String(reflecting: config).contains(token))
    }

    func testHealthCannotListWhenShimAndHostDown() async {
        let client = makeClient(ports: [])
        let health = await client.health()
        XCTAssertEqual(health, .cannotList)
        await XCTAssertThrowsErrorAsync(
            { try await client.sendPrompt(agentID: Self.benchID, prompt: "x") },
            errorHandler: { error in
                XCTAssertEqual(error as? GrokDHostError, .sendRefused(.cannotList))
            }
        )
    }

    func testHealthCanListHostDownRefusesSendEvenIfListAgentsWould200() async {
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false))
        }
        let client = makeClient(ports: [1337, 8787])
        let health = await client.health()
        XCTAssertEqual(health, .canListHostDown)
        XCTAssertEqual(health.userMessage, "local box host is down")
        await XCTAssertThrowsErrorAsync(
            { try await client.sendPrompt(agentID: Self.benchID, prompt: "x") },
            errorHandler: { error in
                XCTAssertEqual(error as? GrokDHostError, .sendRefused(.canListHostDown))
            }
        )
        XCTAssertTrue(GrokDStubURLProtocol.requests.isEmpty, "must not POST sendPrompt when 1338 is down")
    }

    func testHealthCanListCannotCompleteWhenInferenceDown() async {
        let client = makeClient(ports: [1337, 1338])
        let health = await client.health()
        XCTAssertEqual(health, .canListCannotComplete)
        XCTAssertEqual(health.userMessage, "inference proxy is down")
        await XCTAssertThrowsErrorAsync(
            { try await client.sendPrompt(agentID: Self.benchID, prompt: "hi") },
            errorHandler: { error in
                XCTAssertEqual(error as? GrokDHostError, .sendRefused(.canListCannotComplete))
            }
        )
        XCTAssertTrue(GrokDStubURLProtocol.requests.isEmpty)
    }

    func testHealthOkRequiresListAgents200() async {
        GrokDStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.path, "/api/listAgents")
            return Self.json(request, 200, Self.agentJSON(running: false))
        }
        let client = makeClient(ports: [1337, 1338, 8787])
        let health = await client.health()
        XCTAssertEqual(health, .ok)
    }

    func testSendPromptPostsUUIDAwaitTurnFalseAndBearer() async throws {
        let expectedToken = token
        GrokDStubURLProtocol.handler = { request in
            if request.url?.path == "/api/listAgents" {
                return Self.json(request, 200, Self.agentJSON(running: false))
            }
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1337/api/sendPrompt")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(expectedToken)")
            let body = try XCTUnwrap(Self.bodyJSON(request))
            XCTAssertEqual(body["agentId"] as? String, Self.benchID)
            XCTAssertEqual(body["awaitTurn"] as? Bool, false)
            XCTAssertEqual(body["prompt"] as? String, "hello")
            return Self.json(request, 200, #"{"accepted":true}"#)
        }
        let client = makeClient(ports: [1337, 1338, 8787])
        let handle = try await client.sendPrompt(agentID: Self.benchID, prompt: "hello")
        XCTAssertEqual(handle.agentID, Self.benchID)
        XCTAssertFalse(String(describing: handle).contains(token))
    }

    func testSendPromptRejectsNonUUIDName() async {
        let client = makeClient(ports: [1337, 1338, 8787])
        await XCTAssertThrowsErrorAsync(
            { try await client.sendPrompt(agentID: "Robust Bench", prompt: "x") },
            errorHandler: { error in
                XCTAssertEqual(error as? GrokDHostError, .invalidAgentID)
            }
        )
        XCTAssertTrue(GrokDStubURLProtocol.requests.isEmpty)
    }

    func testBusyAgentDrop() async {
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: true))
        }
        let client = makeClient(ports: [1337, 1338, 8787])
        await XCTAssertThrowsErrorAsync(
            { try await client.sendPrompt(agentID: Self.benchID, prompt: "x") },
            errorHandler: { error in
                XCTAssertEqual(error as? GrokDHostError, .agentBusy(id: Self.benchID))
            }
        )
        XCTAssertFalse(GrokDStubURLProtocol.requests.contains(where: { $0.url?.path == "/api/sendPrompt" }))
    }

    func testAutoStartDoesNotRunWhenFlagOffOrSandboxed() async {
        let defaults = UserDefaults(suiteName: "GrokDHostClientTests.autostart.\(UUID().uuidString)")!
        defaults.set(false, forKey: GrokDFeature.DefaultsKey.enabled)
        defaults.set(true, forKey: GrokDFeature.DefaultsKey.autoStart)
        let ran = Locked(false)
        let started = await GrokDFeature.startLocalBoxIfNeeded(defaults: defaults) { _ in
            ran.write(true)
        }
        XCTAssertFalse(started)
        XCTAssertFalse(ran.read())
    }

    func testAutoStartRunsWhenBothFlagsOnAndScriptExists() async throws {
        let script = GrokDHostConfig.defaultEnsureLocalBoxURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: script.path),
            "ensure-local-box.sh not installed"
        )
        try XCTSkipIf(GrokDFeature.isAppSandboxed, "sandboxed host cannot auto-start")
        let defaults = UserDefaults(suiteName: "GrokDHostClientTests.autostart.on.\(UUID().uuidString)")!
        defaults.set(true, forKey: GrokDFeature.DefaultsKey.enabled)
        defaults.set(true, forKey: GrokDFeature.DefaultsKey.autoStart)
        let ran = Locked(false)
        let started = await GrokDFeature.startLocalBoxIfNeeded(defaults: defaults) { _ in
            ran.write(true)
        }
        XCTAssertTrue(started)
        XCTAssertTrue(ran.read())
    }

    func testLocalProfileMissingTokenThrows() throws {
        let env = try makeActiveEnv(token: nil, mode: "local")
        XCTAssertThrowsError(try GrokDHostConfig.load(fromActiveEnv: env)) { error in
            XCTAssertEqual(error as? GrokDHostError, .missingToken)
        }
    }

    func testMissingActiveEnvThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-grokd-env-\(UUID().uuidString).json")
        XCTAssertThrowsError(try GrokDHostConfig.load(fromActiveEnv: url)) { error in
            XCTAssertEqual(error as? GrokDHostError, .missingActiveEnv)
        }
    }

    func testListAgentsAcceptsEnvelope() async throws {
        GrokDStubURLProtocol.handler = { request in
            let envelope = "{\"agents\":" + Self.agentJSON(running: false) + "}"
            return Self.json(request, 200, envelope)
        }
        let agents = try await makeClient(ports: [1337, 1338, 8787]).listAgents()
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.id, Self.benchID)
    }

    func testSendPromptRejectsUnknownAgent() async {
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false))
        }
        let missing = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        await XCTAssertThrowsErrorAsync(
            {
                try await self.makeClient(ports: [1337, 1338, 8787]).sendPrompt(agentID: missing, prompt: "x")
            },
            errorHandler: { error in
                XCTAssertEqual(error as? GrokDHostError, .unknownAgent(id: missing))
            }
        )
        XCTAssertFalse(GrokDStubURLProtocol.requests.contains(where: { $0.url?.path == "/api/sendPrompt" }))
    }

    func testSendPromptRejectsEmptyPrompt() async {
        await XCTAssertThrowsErrorAsync(
            {
                try await self.makeClient(ports: [1337, 1338, 8787]).sendPrompt(agentID: Self.benchID, prompt: "   ")
            },
            errorHandler: { error in
                XCTAssertEqual(error as? GrokDHostError, .emptyPrompt)
            }
        )
        XCTAssertTrue(GrokDStubURLProtocol.requests.isEmpty)
    }

    func testFollowTurnCompletesWhenPreviewChanges() async {
        let prompt = "unique-follow-token-xyz"
        let polls = Locked(0)
        GrokDStubURLProtocol.handler = { request in
            let n = polls.withLock { value -> Int in
                value += 1
                return value
            }
            if n == 1 {
                return Self.json(request, 200, Self.agentJSON(running: true, preview: prompt))
            }
            return Self.json(request, 200, Self.agentJSON(running: false, preview: "assistant pong"))
        }
        let result = await makeClient(ports: [1337, 1338, 8787]).followTurn(
            agentID: Self.benchID,
            prompt: prompt,
            baselinePreview: "old line",
            maxPolls: 4,
            pollNanoseconds: 0
        )
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.lastPreview, "assistant pong")
    }

    func testFollowTurnCompletesWhenFirstPreviewIsEcho() async {
        let prompt = "echo-token-xyz"
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false, preview: "\(prompt) pong"))
        }
        let result = await makeClient(ports: [1337, 1338, 8787]).followTurn(
            agentID: Self.benchID,
            prompt: prompt,
            baselinePreview: "old line",
            maxPolls: 2,
            pollNanoseconds: 0
        )
        XCTAssertEqual(result.outcome, .completed)
    }

    func testFollowTurnReportsPromptLandedWithoutReply() async {
        let prompt = "landed-only-token"
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false, preview: prompt))
        }
        let result = await makeClient(ports: [1337, 1338, 8787]).followTurn(
            agentID: Self.benchID,
            prompt: prompt,
            baselinePreview: "before",
            maxPolls: 2,
            pollNanoseconds: 0
        )
        XCTAssertEqual(result.outcome, .promptLandedNoReply)
    }

    func testHealthCannotListWhenListAgentsFailsWithPortsUp() async {
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 500, #"{"error":"no"}"#)
        }
        let health = await makeClient(ports: [1337, 1338, 8787]).health()
        XCTAssertEqual(health, .cannotList)
    }

    func testBoxModelSendPreservesFollowStatus() async throws {
        let defaults = UserDefaults(suiteName: "GrokDBoxModel.send.\(UUID().uuidString)")!
        defaults.set(true, forKey: GrokDFeature.DefaultsKey.enabled)
        let sent = Locked(0)
        let listsAfterSend = Locked(0)
        GrokDStubURLProtocol.handler = { request in
            if request.url?.path == "/api/sendPrompt" {
                sent.withLock { $0 += 1 }
                return Self.json(request, 200, #"{"accepted":true}"#)
            }
            if sent.read() == 0 {
                return Self.json(request, 200, Self.agentJSON(running: false, preview: "old"))
            }
            let n = listsAfterSend.withLock { value -> Int in
                value += 1
                return value
            }
            if n == 1 {
                return Self.json(request, 200, Self.agentJSON(running: true, preview: "hello-token"))
            }
            return Self.json(request, 200, Self.agentJSON(running: false, preview: "done"))
        }
        let session = self.session!
        let token = self.token
        let model = GrokDBoxModel(
            defaults: defaults,
            makeClient: {
                GrokDHostClient(
                    config: GrokDHostConfig(
                        loopbackHost: "127.0.0.1",
                        shimPort: 1337,
                        hostPort: 1338,
                        inferencePort: 8787,
                        bearerToken: token,
                        guiMode: "local"
                    ),
                    session: session,
                    portProbe: GrokDStubPortProbe(open: [1337, 1338, 8787])
                )
            },
            startBox: { false }
        )
        model.followMaxPolls = 4
        model.followPollNanoseconds = 0
        await model.refresh()
        model.selectedAgentID = Self.benchID
        model.promptText = "hello-token"
        XCTAssertTrue(model.canSend)
        await model.send()
        XCTAssertEqual(model.lastMessage, "Turn completed.")
        XCTAssertEqual(model.statusTone, .success)
        XCTAssertEqual(model.phase, .assistantDone)
        XCTAssertTrue(GrokDStubURLProtocol.requests.contains(where: { $0.url?.path == "/api/sendPrompt" }))
    }

    func testCursorModeMissingTokenUsesLoopbackBearerAndWarns() throws {
        let env = try makeActiveEnv(token: nil, mode: "cursor")
        let config = try GrokDHostConfig.load(fromActiveEnv: env)
        XCTAssertFalse(config.guiIsLocalProfile)
        XCTAssertEqual(config.bearerToken, GrokDHostConfig.localBoxShimBearer)
        XCTAssertFalse(config.description.contains(GrokDHostConfig.localBoxShimBearer))
    }

    func testBoxModelDisabledDoesNotNetwork() async {
        let defaults = UserDefaults(suiteName: "GrokDBoxModel.off.\(UUID().uuidString)")!
        defaults.set(false, forKey: GrokDFeature.DefaultsKey.enabled)
        let listed = Locked<Int>(0)
        let session = self.session!
        let token = self.token
        let model = GrokDBoxModel(defaults: defaults) {
            listed.withLock { $0 += 1 }
            return GrokDHostClient(
                config: GrokDHostConfig(
                    loopbackHost: "127.0.0.1",
                    shimPort: 1337,
                    hostPort: 1338,
                    inferencePort: 8787,
                    bearerToken: token,
                    guiMode: "local"
                ),
                session: session,
                portProbe: GrokDStubPortProbe(open: [1337, 1338, 8787])
            )
        }
        await model.refresh()
        XCTAssertEqual(listed.read(), 0)
        XCTAssertEqual(model.title, "Local D box (0 live agents)")
        XCTAssertEqual(model.phase, .off)
        XCTAssertFalse(model.canSend)
    }

    func testBoxModelHostDownRefusesSend() async {
        let defaults = UserDefaults(suiteName: "GrokDBoxModel.hostdown.\(UUID().uuidString)")!
        defaults.set(true, forKey: GrokDFeature.DefaultsKey.enabled)
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false))
        }
        let session = self.session!
        let token = self.token
        let model = GrokDBoxModel(defaults: defaults) {
            GrokDHostClient(
                config: GrokDHostConfig(
                    loopbackHost: "127.0.0.1",
                    shimPort: 1337,
                    hostPort: 1338,
                    inferencePort: 8787,
                    bearerToken: token,
                    guiMode: "local"
                ),
                session: session,
                portProbe: GrokDStubPortProbe(open: [1337, 8787])
            )
        }
        await model.refresh()
        XCTAssertEqual(model.health, .canListHostDown)
        XCTAssertEqual(model.phase, .refused)
        XCTAssertEqual(model.agents.count, 1)
        model.selectedAgentID = Self.benchID
        model.promptText = "hello"
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.lastMessage, "local box host is down")
        await model.send()
        XCTAssertTrue(GrokDStubURLProtocol.requests.allSatisfy { $0.url?.path != "/api/sendPrompt" })
    }

    func testLiveHealthRefusesUnlessAllPortsUp() async throws {
        let probe = GrokDTCPPortProbe()
        let shim = probe.isListening(host: "127.0.0.1", port: 1337)
        try XCTSkipUnless(shim, "Local D shim :1337 is down")
        let envURL = GrokDHostConfig.defaultActiveEnvURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: envURL.path), "active-env.json missing")
        let config = try GrokDHostConfig.load(fromActiveEnv: envURL)
        let client = GrokDHostClient(config: config, portProbe: probe)
        let host = probe.isListening(host: "127.0.0.1", port: 1338)
        let inference = probe.isListening(host: "127.0.0.1", port: 8787)
        let started = Date()
        let health = await client.health()
        if !host {
            XCTAssertEqual(health, .canListHostDown)
            XCTAssertEqual(health.userMessage, "local box host is down")
        } else if !inference {
            XCTAssertEqual(health, .canListCannotComplete)
            XCTAssertEqual(health.userMessage, "inference proxy is down")
        } else {
            XCTAssertEqual(health, .ok)
            return
        }
        do {
            _ = try await client.sendPrompt(agentID: Self.benchID, prompt: "should-not-run")
            XCTFail("send must refuse when health is \(health)")
        } catch let error as GrokDHostError {
            XCTAssertEqual(error, .sendRefused(health))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    func testLiveLoopbackHealthSkipsWhenPortsDown() async throws {
        let probe = GrokDTCPPortProbe()
        let shim = probe.isListening(host: "127.0.0.1", port: 1337)
        let host = probe.isListening(host: "127.0.0.1", port: 1338)
        let inference = probe.isListening(host: "127.0.0.1", port: 8787)
        try XCTSkipUnless(shim && host && inference, "Local D ports 1337/1338/8787 are down")
        let envURL = GrokDHostConfig.defaultActiveEnvURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: envURL.path), "active-env.json missing")
        let config = try GrokDHostConfig.load(fromActiveEnv: envURL)
        let client = GrokDHostClient(config: config, portProbe: probe)
        let health = await client.health()
        XCTAssertEqual(health, .ok)
        let agents = try await client.listAgents()
        XCTAssertFalse(agents.isEmpty)
        XCTAssertTrue(agents.allSatisfy { GrokDHostClient.isAgentUUID($0.id) })
    }

    func testListAgentsDecodesStorePath() async throws {
        let db = "/tmp/box/7fa6a3c4-9f24-46be-9795-396308b0f612/store.db"
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false, path: db))
        }
        let agents = try await makeClient(ports: [1337, 1338, 8787]).listAgents()
        XCTAssertEqual(agents.first?.path, db)
    }

    func testTranscriptInterpretUserThenAssistantIsCompleted() {
        let token = "unique-sqlite-token"
        let user = #"{"kind":"message","role":"user","content":"\#(token)"}"#
        let assistant = #"{"kind":"send-message","message":{"type":"text","content":"pong"}}"#
        let assistantRole = #"{"kind":"message","role":"assistant","content":"pong"}"#
        XCTAssertEqual(
            GrokDReadonlyTranscriptReader.interpret(entriesNewestFirst: [assistant, user], token: token),
            .completed
        )
        XCTAssertEqual(
            GrokDReadonlyTranscriptReader.interpret(entriesNewestFirst: [assistantRole, user], token: token),
            .completed
        )
        XCTAssertEqual(
            GrokDReadonlyTranscriptReader.interpret(entriesNewestFirst: [user], token: token),
            .promptLanded
        )
        XCTAssertEqual(
            GrokDReadonlyTranscriptReader.interpret(entriesNewestFirst: [assistant], token: token),
            .noEvidence
        )
        let envelope = #"{"kind":"message","role":"user","content":"hello","isStreaming":false}"#
        XCTAssertEqual(
            GrokDReadonlyTranscriptReader.interpret(entriesNewestFirst: [assistant, envelope], token: "message"),
            .noEvidence
        )
        XCTAssertEqual(
            GrokDReadonlyTranscriptReader.interpret(entriesNewestFirst: [assistant, envelope], token: "false"),
            .noEvidence
        )
        let oldUser = #"{"kind":"message","role":"user","content":"please say hi"}"#
        let oldAssistant = #"{"kind":"send-message","message":{"type":"text","content":"hi"}}"#
        let newUser = #"{"kind":"message","role":"user","content":"hi"}"#
        XCTAssertEqual(
            GrokDReadonlyTranscriptReader.interpret(
                entriesNewestFirst: [newUser, oldAssistant, oldUser],
                token: "hi"
            ),
            .promptLanded
        )
    }

    func testReadonlySqliteFollowSucceedsWhenPreviewStillLooksLikeThePrompt() async throws {
        let token = "sqlite-follow-token"
        let db = try Self.makeTempStoreDB(entries: [
            #"{"kind":"message","role":"user","content":"\#(token)"}"#,
            #"{"kind":"send-message","message":{"type":"text","content":"pong"}}"#
        ])
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false, preview: token, path: db.path))
        }
        let result = await makeClient(ports: [1337, 1338, 8787]).followTurn(
            agentID: Self.benchID,
            prompt: token,
            baselinePreview: "old",
            maxPolls: 2,
            pollNanoseconds: 0
        )
        XCTAssertEqual(result.outcome, .completed)
    }

    func testReadonlySqliteBusySkipsAndFallsBackToPreview() async throws {
        let token = "busy-follow-token"
        let db = try Self.makeTempStoreDB(entries: [
            #"{"kind":"message","role":"user","content":"\#(token)"}"#
        ])
        let locked = try Self.makeSqliteShim(mode: "locked")
        let reader = GrokDReadonlyTranscriptReader(
            busyTimeoutMilliseconds: 0,
            sqlite3URL: locked.script
        )
        let busy = await reader.read(path: db.path, agentID: Self.benchID, token: token)
        XCTAssertEqual(busy, .skippedBusy)
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false, preview: token, path: db.path))
        }
        let client = GrokDHostClient(
            config: GrokDHostConfig(
                loopbackHost: "127.0.0.1",
                shimPort: 1337,
                hostPort: 1338,
                inferencePort: 8787,
                bearerToken: self.token,
                guiMode: "local"
            ),
            session: session,
            portProbe: GrokDStubPortProbe(open: [1337, 1338, 8787]),
            transcriptReader: reader
        )
        let result = await client.followTurn(
            agentID: Self.benchID,
            prompt: token,
            baselinePreview: "old",
            maxPolls: 2,
            pollNanoseconds: 0
        )
        XCTAssertEqual(result.outcome, .promptLandedNoReply)
    }

    func testReadonlySqliteNeverWrites() async throws {
        let token = "never-write-token"
        let db = try Self.makeTempStoreDB(entries: [
            #"{"kind":"message","role":"user","content":"\#(token)"}"#
        ])
        let shim = try Self.makeSqliteShim(mode: "passthrough")
        let before = try Self.sqliteQuery(db, "SELECT COUNT(*) FROM transcript_entries;")
        let bytesBefore = try Data(contentsOf: db)
        let reader = GrokDReadonlyTranscriptReader(
            busyTimeoutMilliseconds: 0,
            sqlite3URL: shim.script
        )
        let landed = await reader.read(path: db.path, agentID: Self.benchID, token: token)
        XCTAssertEqual(landed, .promptLanded)
        let argv = try String(contentsOf: shim.log, encoding: .utf8)
        XCTAssertTrue(argv.contains("-readonly"))
        XCTAssertTrue(argv.contains("SELECT entry FROM transcript_entries"))
        XCTAssertFalse(argv.contains("INSERT"))
        XCTAssertFalse(argv.contains("UPDATE"))
        XCTAssertFalse(argv.contains("DELETE"))
        let insertRC = Self.sqliteStatus(
            db,
            "INSERT INTO transcript_entries (id, entry) VALUES ('should-fail', 'x');",
            readonly: true
        )
        XCTAssertNotEqual(insertRC, 0)
        let after = try Self.sqliteQuery(db, "SELECT COUNT(*) FROM transcript_entries;")
        let bytesAfter = try Data(contentsOf: db)
        XCTAssertEqual(before, after)
        XCTAssertEqual(bytesBefore, bytesAfter)
    }

    func testReadonlySqliteMissingDbFallsBackToPreview() async throws {
        let token = "missing-db-token"
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokd-miss-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("box-data", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(Self.benchID, isDirectory: true)
            .appendingPathComponent("store.db")
        let reader = GrokDReadonlyTranscriptReader(busyTimeoutMilliseconds: 0)
        let missingRead = await reader.read(path: missing.path, agentID: Self.benchID, token: token)
        XCTAssertEqual(missingRead, .unavailable)
        let junk = await reader.read(path: "/tmp/not-a-store.sqlite", agentID: Self.benchID, token: token)
        XCTAssertEqual(junk, .unavailable)
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false, preview: token, path: missing.path))
        }
        let result = await makeClient(ports: [1337, 1338, 8787]).followTurn(
            agentID: Self.benchID,
            prompt: token,
            baselinePreview: "old",
            maxPolls: 2,
            pollNanoseconds: 0
        )
        XCTAssertEqual(result.outcome, .promptLandedNoReply)
    }

    func testReadonlySqliteUserRowWithoutAssistantIsPromptLanded() async throws {
        let token = "user-only-token"
        let db = try Self.makeTempStoreDB(entries: [
            #"{"kind":"message","role":"user","content":"\#(token)"}"#
        ])
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false, preview: token, path: db.path))
        }
        let result = await makeClient(ports: [1337, 1338, 8787]).followTurn(
            agentID: Self.benchID,
            prompt: token,
            baselinePreview: "old",
            maxPolls: 2,
            pollNanoseconds: 0
        )
        XCTAssertEqual(result.outcome, .promptLandedNoReply)
    }

    func testBoxViewEnableEmptyRosterSendDisabledAndSearchAnchor() async {
        XCTAssertTrue(SettingsManifest.visibleAnchorIDs.contains(SettingsAnchor.agentsLocalDBox))
        let offDefaults = UserDefaults(suiteName: "GrokDBoxView.off.\(UUID().uuidString)")!
        offDefaults.set(false, forKey: GrokDFeature.DefaultsKey.enabled)
        let offModel = GrokDBoxModel(defaults: offDefaults) {
            XCTFail("disabled pane must not construct a client")
            return self.makeClient(ports: [1337, 1338, 8787])
        }
        await offModel.refresh()
        XCTAssertEqual(offModel.phase, .off)
        XCTAssertTrue(offModel.agents.isEmpty)
        XCTAssertFalse(offModel.canSend)
        XCTAssertEqual(offModel.lastMessage, "Local D box is off.")
        _ = GrokDBoxView(model: offModel).body

        let defaults = UserDefaults(suiteName: "GrokDBoxView.hostdown.\(UUID().uuidString)")!
        defaults.set(true, forKey: GrokDFeature.DefaultsKey.enabled)
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, "[]")
        }
        let session = self.session!
        let token = self.token
        let model = GrokDBoxModel(defaults: defaults) {
            GrokDHostClient(
                config: GrokDHostConfig(
                    loopbackHost: "127.0.0.1",
                    shimPort: 1337,
                    hostPort: 1338,
                    inferencePort: 8787,
                    bearerToken: token,
                    guiMode: "local"
                ),
                session: session,
                portProbe: GrokDStubPortProbe(open: [1337, 8787])
            )
        }
        await model.refresh()
        XCTAssertEqual(model.health, .canListHostDown)
        XCTAssertEqual(model.phase, .refused)
        XCTAssertTrue(model.agents.isEmpty)
        model.promptText = "hello"
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.lastMessage, "local box host is down")
        XCTAssertEqual(model.statusTone, .warning)
        _ = GrokDBoxView(model: model).body

        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, "[]")
        }
        let okDefaults = UserDefaults(suiteName: "GrokDBoxView.okempty.\(UUID().uuidString)")!
        okDefaults.set(true, forKey: GrokDFeature.DefaultsKey.enabled)
        let okModel = GrokDBoxModel(defaults: okDefaults) {
            GrokDHostClient(
                config: GrokDHostConfig(
                    loopbackHost: "127.0.0.1",
                    shimPort: 1337,
                    hostPort: 1338,
                    inferencePort: 8787,
                    bearerToken: token,
                    guiMode: "local"
                ),
                session: session,
                portProbe: GrokDStubPortProbe(open: [1337, 1338, 8787])
            )
        }
        await okModel.refresh()
        XCTAssertEqual(okModel.health, .ok)
        XCTAssertEqual(okModel.phase, .ready)
        XCTAssertTrue(okModel.agents.isEmpty)
        okModel.promptText = "hello"
        XCTAssertFalse(okModel.canSend)
        XCTAssertEqual(okModel.sendBlockedReason, "Select a live agent.")
        _ = GrokDBoxView(model: okModel).body

        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false))
        }
        let infDefaults = UserDefaults(suiteName: "GrokDBoxView.inf.\(UUID().uuidString)")!
        infDefaults.set(true, forKey: GrokDFeature.DefaultsKey.enabled)
        let infModel = GrokDBoxModel(defaults: infDefaults) {
            GrokDHostClient(
                config: GrokDHostConfig(
                    loopbackHost: "127.0.0.1",
                    shimPort: 1337,
                    hostPort: 1338,
                    inferencePort: 8787,
                    bearerToken: token,
                    guiMode: "local"
                ),
                session: session,
                portProbe: GrokDStubPortProbe(open: [1337, 1338])
            )
        }
        await infModel.refresh()
        XCTAssertEqual(infModel.health, .canListCannotComplete)
        XCTAssertEqual(infModel.lastMessage, "inference proxy is down")
        infModel.promptText = "hello"
        infModel.selectedAgentID = Self.benchID
        XCTAssertFalse(infModel.canSend)
        _ = GrokDBoxView(model: infModel).body
    }

    func testLiveProbeBotUniqueTokenFollow() async throws {
        let probe = GrokDTCPPortProbe()
        try XCTSkipUnless(
            probe.isListening(host: "127.0.0.1", port: 1337)
                && probe.isListening(host: "127.0.0.1", port: 1338)
                && probe.isListening(host: "127.0.0.1", port: 8787),
            "Local D ports 1337/1338/8787 are down"
        )
        let envURL = GrokDHostConfig.defaultActiveEnvURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: envURL.path), "active-env.json missing")
        let config = try GrokDHostConfig.load(fromActiveEnv: envURL)
        let client = GrokDHostClient(config: config, portProbe: probe)
        let health = await client.health()
        XCTAssertEqual(health, .ok)
        let agents = try await client.listAgents()
        let bot = agents.first { $0.name == "Probe Bot" && GrokDHostClient.isAgentUUID($0.id) && !$0.isBusy }
        guard let bot else {
            throw XCTSkip("idle Probe Bot missing")
        }
        let token = "BBLOCALD-AUDIT-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let started = Date()
        do {
            _ = try await client.sendPrompt(agentID: bot.id, prompt: token)
        } catch let error as GrokDHostError {
            switch error {
            case .agentBusy, .sendRefused:
                throw XCTSkip("Probe Bot refused send")
            default:
                throw error
            }
        }
        let result = await client.followTurn(
            agentID: bot.id,
            prompt: token,
            baselinePreview: bot.lastMessagePreview,
            maxPolls: 30,
            pollNanoseconds: 1_000_000_000
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 35)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertTrue((result.lastPreview ?? "").contains(token))
    }

    // MARK: - Helpers

    private nonisolated static let benchID = "7fa6a3c4-9f24-46be-9795-396308b0f612"

    private func makeClient(ports: Set<UInt16>) -> GrokDHostClient {
        let config = GrokDHostConfig(
            loopbackHost: "127.0.0.1",
            shimPort: 1337,
            hostPort: 1338,
            inferencePort: 8787,
            bearerToken: token,
            guiMode: "local"
        )
        return GrokDHostClient(
            config: config,
            session: session,
            portProbe: GrokDStubPortProbe(open: ports)
        )
    }

    private func makeActiveEnv(token: String?, mode: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grokd-env-\(UUID().uuidString).json")
        let body: String
        if let token {
            body = #"{"mode":"\#(mode)","SAND_HOST_GATEWAY_TOKEN":"\#(token)"}"#
        } else {
            body = #"{"mode":"\#(mode)"}"#
        }
        try Data(body.utf8).write(to: url)
        return url
    }

    private nonisolated static func agentJSON(running: Bool, preview: String? = nil, path: String? = nil) -> String {
        var extra = ""
        if let preview {
            extra += ",\"lastMessagePreview\":\"\(preview)\""
        }
        if let path {
            extra += ",\"path\":\"\(path)\""
        }
        return """
        [{"id":"\(benchID)","name":"Robust Bench","isRunning":\(running),"isComposingMessage":false\(extra)}]
        """
    }

    private nonisolated static func makeTempStoreDB(entries: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokd-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("box-data", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(benchID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("store.db")
        var sql = "CREATE TABLE transcript_entries (id TEXT, entry TEXT);\n"
        for (index, entry) in entries.enumerated() {
            let escaped = entry.replacingOccurrences(of: "'", with: "''")
            sql += "INSERT INTO transcript_entries (id, entry) VALUES ('e\(index)', '\(escaped)');\n"
        }
        let rc = sqliteStatus(db, sql, readonly: false)
        if rc != 0 {
            throw NSError(domain: "GrokDHostClientTests", code: Int(rc))
        }
        return db
    }

    @discardableResult
    private nonisolated static func sqliteStatus(_ db: URL, _ sql: String, readonly: Bool) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        var args = ["-batch"]
        if readonly { args.append("-readonly") }
        args.append(contentsOf: [db.path, sql])
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private nonisolated static func sqliteQuery(_ db: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", db.path, sql]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private nonisolated static func makeSqliteShim(mode: String) throws -> (script: URL, log: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "grokd-sqlite-shim-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("argv.log")
        let script = dir.appendingPathComponent("sqlite3-shim.sh")
        let body: String
        if mode == "locked" {
            body = "#!/bin/bash\necho \"database is locked\" >&2\nexit 5\n"
        } else {
            body = """
            #!/bin/bash
            : > '\(log.path)'
            for a in "$@"; do
              printf '%s\\n' "$a" >> '\(log.path)'
            done
            exec /usr/bin/sqlite3 "$@"
            """
        }
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, log)
    }

    private nonisolated static func json(_ request: URLRequest, _ status: Int, _ body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }

    private nonisolated static func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.flatMap { stream in
            let buffer = NSMutableData()
            stream.open()
            let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { tmp.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(tmp, maxLength: 4096)
                if n > 0 { buffer.append(tmp, length: n) } else { break }
            }
            return buffer as Data
        })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct GrokDStubPortProbe: GrokDPortProbing {
    var open: Set<UInt16>
    func isListening(host: String, port: UInt16) -> Bool {
        host == "127.0.0.1" && open.contains(port)
    }
}

private final class GrokDStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let handlerLock = Locked<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static let requestLock = Locked<[URLRequest]>([])

    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerLock.read() }
        set { handlerLock.write(newValue) }
    }

    static var requests: [URLRequest] {
        get { requestLock.read() }
        set { requestLock.write(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestLock.withLock { $0.append(request) }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
