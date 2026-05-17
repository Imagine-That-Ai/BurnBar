import XCTest
@testable import OpenBurnBarComputerUseCore

final class ComputerUseOpenTimestampsClientTests: XCTestCase {
    func testProofFilenameDerivation() {
        let chain = URL(fileURLWithPath: "/tmp/cu/chain.jsonl")
        let proof = ComputerUseOpenTimestampsClient.proofFilename(forChainAt: chain)
        XCTAssertEqual(proof.lastPathComponent, "chain.jsonl.ots")
    }

    func testDigestLengthGuard() async {
        let client = ComputerUseOpenTimestampsClient()
        await assertThrowsAsync({
            _ = try await client.notarize(digest: Data(repeating: 0xAA, count: 64))
        }) { error in
            guard case ComputerUseOpenTimestampsClient.ClientError.digestTooLong = error else {
                XCTFail("expected digestTooLong, got \(error)")
                return
            }
        }
    }

    func testNotarizeHashesArbitraryHex() async {
        // We don't make the network call here — instead inject a stub
        // URLSession that records the outgoing request body.
        let recorder = RecordingURLProtocol()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ComputerUseOpenTimestampsClient(
            configuration: .init(calendarURL: URL(string: "https://otc.test/digest")!),
            urlSession: session
        )
        let chainHead = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        RecordingURLProtocol.canonicalResponse = .success(
            response: HTTPURLResponse(
                url: URL(string: "https://otc.test/digest")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!,
            data: Data([0xFE, 0xED, 0xFA, 0xCE])
        )
        let proof = try? await client.notarize(auditChainHeadHashHex: chainHead)
        XCTAssertEqual(proof, Data([0xFE, 0xED, 0xFA, 0xCE]))
        XCTAssertEqual(RecordingURLProtocol.lastBody?.count, 32,
            "Calendar bodies must be exactly the 32-byte digest.")
        _ = recorder
    }

    func testArchiveWritesProofAndSidecar() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ots-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let chainURL = tmp.appendingPathComponent("chain.jsonl")
        try Data("{}\n".utf8).write(to: chainURL)
        let proof = Data([0x01, 0x02, 0x03, 0x04])
        let calendar = URL(string: "https://a.pool.opentimestamps.org/digest")!
        let written = try ComputerUseOpenTimestampsArchive.writeProof(
            proofBytes: proof,
            sourceChainURL: chainURL,
            calendarURL: calendar
        )
        XCTAssertEqual(written.lastPathComponent, "chain.jsonl.ots")
        let sidecarURL = chainURL.deletingPathExtension().appendingPathExtension("jsonl.ots.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
        let sidecar = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any]
        XCTAssertEqual(sidecar?["chainFile"] as? String, "chain.jsonl")
        XCTAssertEqual(sidecar?["calendar"] as? String, calendar.absoluteString)
        XCTAssertEqual(sidecar?["proofSizeBytes"] as? Int, 4)
    }

    // MARK: helpers

    private func assertThrowsAsync<T>(
        _ block: @escaping () async throws -> T,
        file: StaticString = #file,
        line: UInt = #line,
        _ inspect: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await block()
            XCTFail("Expected throw", file: file, line: line)
        } catch {
            inspect(error)
        }
    }
}

private final class RecordingURLProtocol: URLProtocol {
    static var canonicalResponse: Outcome = .success(
        response: HTTPURLResponse(url: URL(string: "about:blank")!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        data: Data()
    )
    static var lastBody: Data?

    enum Outcome {
        case success(response: HTTPURLResponse, data: Data)
        case failure(Error)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol can be invoked with the body either as
        // httpBody or httpBodyStream depending on how the URLSession
        // was configured; capture from whichever is present.
        if let body = request.httpBody {
            RecordingURLProtocol.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 256)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            stream.close()
            RecordingURLProtocol.lastBody = collected
        }
        switch RecordingURLProtocol.canonicalResponse {
        case .success(let response, let data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
