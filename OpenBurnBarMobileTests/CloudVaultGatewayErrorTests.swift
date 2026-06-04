import XCTest
import FirebaseFunctions
@testable import OpenBurnBarMobile

/// Guards the transcript-download failure mapping: the cockpit must turn each distinct cause into a
/// precise, actionable error instead of collapsing everything into an opaque "Could not download the
/// encrypted session log" with a futile "Try Again". These are pure assertions on the classifier and
/// the localized strings — no Functions/Storage round-trip required.
final class CloudVaultGatewayErrorTests: XCTestCase {

    // MARK: - classifyDownloadFailure

    func testHTTPNotFoundMapsToMissingFromCloud() {
        XCTAssertEqual(
            CloudVaultGateway.classifyDownloadFailure(httpStatus: 404, error: nil),
            .transcriptMissingFromCloud
        )
    }

    func testHTTPGoneMapsToMissingFromCloud() {
        XCTAssertEqual(
            CloudVaultGateway.classifyDownloadFailure(httpStatus: 410, error: nil),
            .transcriptMissingFromCloud
        )
    }

    func testCallableNotFoundMapsToMissingFromCloud() {
        let notFound = NSError(
            domain: FunctionsErrorDomain,
            code: FunctionsErrorCode.notFound.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "The encrypted session log is no longer stored in the cloud."]
        )
        XCTAssertEqual(
            CloudVaultGateway.classifyDownloadFailure(httpStatus: nil, error: notFound),
            .transcriptMissingFromCloud
        )
    }

    func testServerErrorPreservesHTTPStatus() {
        XCTAssertEqual(
            CloudVaultGateway.classifyDownloadFailure(httpStatus: 500, error: nil),
            .downloadFailed(underlying: "HTTP 500")
        )
    }

    func testForbiddenPreservesHTTPStatus() {
        // 403 is recoverable (e.g. an expired signed URL), so it stays a generic retryable failure
        // that surfaces the status rather than masquerading as a permanently missing transcript.
        XCTAssertEqual(
            CloudVaultGateway.classifyDownloadFailure(httpStatus: 403, error: nil),
            .downloadFailed(underlying: "HTTP 403")
        )
    }

    func testArbitraryErrorPreservesItsMessage() {
        let network = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )
        XCTAssertEqual(
            CloudVaultGateway.classifyDownloadFailure(httpStatus: nil, error: network),
            .downloadFailed(underlying: "The request timed out.")
        )
    }

    func testNoStatusOrErrorIsAGenericFailure() {
        XCTAssertEqual(
            CloudVaultGateway.classifyDownloadFailure(httpStatus: nil, error: nil),
            .downloadFailed(underlying: nil)
        )
    }

    // MARK: - errorDescription

    func testEachErrorHasADistinctActionableMessage() {
        XCTAssertEqual(
            CloudConversationSearchError.transcriptUnavailable.errorDescription,
            "This conversation was indexed without a stored transcript, so there's nothing to open."
        )
        XCTAssertEqual(
            CloudConversationSearchError.transcriptMissingFromCloud.errorDescription,
            "This conversation's encrypted transcript is no longer stored in the cloud."
        )
        XCTAssertEqual(
            CloudConversationSearchError.downloadFailed(underlying: "HTTP 500").errorDescription,
            "Could not download the encrypted session log: HTTP 500"
        )
        XCTAssertEqual(
            CloudConversationSearchError.downloadFailed(underlying: nil).errorDescription,
            "Could not download the encrypted session log."
        )
        XCTAssertEqual(
            CloudConversationSearchError.downloadFailed(underlying: "").errorDescription,
            "Could not download the encrypted session log."
        )
    }

    // MARK: - loadTranscript guard

    @MainActor
    func testLoadTranscriptWithoutStoragePathReportsUnavailableWithoutNetwork() async {
        let store = ConversationCockpitStore()
        let row = Self.makeRow(storagePath: nil, bodyHash: nil)
        do {
            _ = try await store.loadTranscript(for: row)
            XCTFail("Expected loadTranscript to throw for a row with no stored body")
        } catch let error as CloudConversationSearchError {
            XCTAssertEqual(error, .transcriptUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testLoadTranscriptWithEmptyStoragePathReportsUnavailable() async {
        let store = ConversationCockpitStore()
        let row = Self.makeRow(storagePath: "", bodyHash: "")
        do {
            _ = try await store.loadTranscript(for: row)
            XCTFail("Expected loadTranscript to throw for a row with an empty storage path")
        } catch let error as CloudConversationSearchError {
            XCTAssertEqual(error, .transcriptUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Fixtures

    private static func makeRow(storagePath: String?, bodyHash: String?) -> CockpitConversationRow {
        CockpitConversationRow(
            id: "device-1_session-1",
            provider: "Claude",
            projectName: "LaHormigaDormida",
            model: "unknown",
            sourceType: "provider_log",
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            totalTokens: 9_300,
            costUSD: 0,
            workingDirectory: "~/Developer/LaHormigaDormida",
            toolTags: [],
            durationSeconds: nil,
            startTime: nil,
            updatedAt: nil,
            title: "Conversation",
            preview: "You are an elite swarm…",
            storagePath: storagePath,
            bodyHash: bodyHash,
            bodyHashVersion: 0
        )
    }
}
