import Foundation
import OpenBurnBarCore
import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBar

final class DomainCoreShadowEvidenceSpoolTests: XCTestCase {
    func testSampleEncodingUsesExactPrivacySafeSchemaIncludingNullCategory() throws {
        let sample = try XCTUnwrap(makeSample())
        let data = try JSONEncoder().encode(sample)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set([
            "schemaVersion", "sampleId", "domain", "slice", "consumer", "channel", "operation",
            "candidateCommit", "expectedCoreVersion", "expectedCoreAbiVersion", "expectedCoreSourceSha256",
            "loadedCoreVersion", "loadedCoreAbiVersion", "loadedCoreSourceSha256",
            "observedAt", "outcome", "mismatchCategory", "legacyMicros", "rustMicros"
        ]))
        XCTAssertEqual(DomainCoreShadowSampleV3.storedKeys.count, 19)
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        XCTAssertEqual(object["candidateCommit"] as? String, candidateCommit)
        XCTAssertTrue(object["mismatchCategory"] is NSNull)
        let mismatch = try XCTUnwrap(makeSample(
            outcome: .mismatch,
            mismatchCategory: .nativeError
        ))
        let mismatchData = try JSONEncoder().encode(mismatch)
        let mismatchObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mismatchData) as? [String: Any]
        )
        XCTAssertEqual(mismatchObject["mismatchCategory"] as? String, "native_error")
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("uid"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("payload"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("deviceId"))
    }

    func testSampleValidationRejectsUnsafeOrContractInvalidComparisons() throws {
        XCTAssertNil(makeSample(channel: "production"))
        XCTAssertNil(makeSample(operation: "unknown_quota"))
        XCTAssertNil(makeSample(outcome: .match, mismatchCategory: .resultMismatch))
        XCTAssertNil(makeSample(outcome: .mismatch))
        XCTAssertNil(makeSample(legacyMicros: 600_000_001))
        XCTAssertNil(makeSample(rustMicros: 600_000_001))

        let boundary = try XCTUnwrap(makeSample(
            channel: "beta",
            outcome: .mismatch,
            mismatchCategory: .nativeError,
            legacyMicros: 600_000_000,
            rustMicros: 600_000_000
        ))
        XCTAssertEqual(boundary.channel, "beta")
        XCTAssertEqual(boundary.outcome, "mismatch")
        XCTAssertEqual(boundary.mismatchCategory, "native_error")
    }

    func testLoadedIdentityMismatchIsCandidateBoundAndLegacyResultRemainsEvidenceOnly() throws {
        let mismatchedLoadedIdentity = DomainCoreEvidenceLoadedIdentity(
            coreVersion: "0.3.1",
            abiVersion: 3,
            sourceSha256: sourceSha256
        )
        let sample = try XCTUnwrap(makeSample(loadedIdentity: mismatchedLoadedIdentity))

        XCTAssertEqual(sample.outcome, "mismatch")
        XCTAssertEqual(sample.mismatchCategory, "loaded_identity_mismatch")
        XCTAssertEqual(sample.expectedCoreVersion, "0.3.0")
        XCTAssertEqual(sample.loadedCoreVersion, "0.3.1")
    }

    func testMissingLoadedIdentityNormalizesNativeErrorToUnavailableWithNullTuple() throws {
        let sample = try XCTUnwrap(makeSample(
            outcome: .mismatch,
            mismatchCategory: .nativeError,
            loadedIdentityAvailable: false
        ))

        XCTAssertEqual(sample.outcome, "mismatch")
        XCTAssertEqual(sample.mismatchCategory, "native_unavailable")
        XCTAssertNil(sample.loadedCoreVersion)
        XCTAssertNil(sample.loadedCoreAbiVersion)
        XCTAssertNil(sample.loadedCoreSourceSha256)
    }

    func testReadableIdentityOverridesUpstreamUnavailableClassification() throws {
        let matching = try XCTUnwrap(makeSample(
            outcome: .mismatch,
            mismatchCategory: .nativeUnavailable
        ))
        XCTAssertEqual(matching.mismatchCategory, "native_error")
        XCTAssertEqual(matching.loadedCoreAbiVersion, 3)

        let wrongABI = try XCTUnwrap(makeSample(
            outcome: .mismatch,
            mismatchCategory: .nativeUnavailable,
            loadedIdentity: DomainCoreEvidenceLoadedIdentity(
                coreVersion: "0.3.0",
                abiVersion: 4,
                sourceSha256: sourceSha256
            )
        ))
        XCTAssertEqual(wrongABI.mismatchCategory, "loaded_identity_mismatch")
        XCTAssertEqual(wrongABI.loadedCoreAbiVersion, 4)
    }

    func testSpoolDropsDifferentCandidateAndNeverTraversesSiblingCandidateDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let activeCandidate = try XCTUnwrap(signedCandidate())
        let staleCandidate = try XCTUnwrap(signedCandidate(commit: String(repeating: "c", count: 40)))
        let activeDirectory = root.appendingPathComponent(
            MacDomainCoreShadowEvidenceRecorder.candidateNamespace(activeCandidate),
            isDirectory: true
        )
        let staleDirectory = root.appendingPathComponent(
            MacDomainCoreShadowEvidenceRecorder.candidateNamespace(staleCandidate),
            isDirectory: true
        )
        let staleSpool = try DomainCoreShadowEvidenceSpool(directory: staleDirectory, maxSamplesPerFile: 1)
        try staleSpool.append(try XCTUnwrap(makeSample(candidate: staleCandidate)))
        let activeSpool = try DomainCoreShadowEvidenceSpool(directory: activeDirectory, maxSamplesPerFile: 1)
        try activeSpool.append(try XCTUnwrap(makeSample()))

        let batch = try XCTUnwrap(activeSpool.nextBatch(
            matchingChannel: "internal",
            matchingCandidate: activeCandidate
        ))
        XCTAssertEqual(batch.samples.map(\.candidateCommit), [activeCandidate.candidateCommit])
        XCTAssertEqual(try staleSpool.pendingSampleCount(), 1)
    }

    func testStartupDeletesLegacyQueuesAndStaleCandidateNamespacesWithoutRelabeling() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":2}\n".utf8).write(
            to: root.appendingPathComponent("active.jsonl")
        )
        let staleV2 = root.appendingPathComponent("v2-old-candidate", isDirectory: true)
        let staleV3 = root.appendingPathComponent("v3-old-candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: staleV2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staleV3, withIntermediateDirectories: true)
        let candidate = try XCTUnwrap(signedCandidate())
        let active = root.appendingPathComponent(
            MacDomainCoreShadowEvidenceRecorder.candidateNamespace(candidate),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: active.appendingPathComponent("sentinel"))

        let prepared = try MacDomainCoreShadowEvidenceRecorder.prepareCandidateDirectory(
            base: root,
            candidate: candidate
        )

        XCTAssertEqual(prepared, active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("active.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleV2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleV3.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.appendingPathComponent("sentinel").path))
    }

    func testRotationBoundsFilesAndDropsOldestWholeBatch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(
            directory: directory,
            maxFileBytes: 4_096,
            maxReadyFiles: 2,
            maxSamplesPerFile: 1
        )

        try spool.append(try XCTUnwrap(makeSample(micros: 1)))
        try spool.append(try XCTUnwrap(makeSample(micros: 2)))
        try spool.append(try XCTUnwrap(makeSample(micros: 3)))
        let batch = try XCTUnwrap(spool.nextBatch())

        XCTAssertEqual(try spool.pendingSampleCount(), 2)
        let readyFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("ready-") }
        XCTAssertEqual(readyFiles.count, 2)
        XCTAssertEqual(batch.samples.single?.legacyMicros, 2)
        XCTAssertEqual(batch.token, "ready-00000000000000000001.jsonl")
    }

    func testGenericCollectorBuildsValidatedV3SamplesForEveryAppleDomain() throws {
        for (domain, slice, operation) in [
            ("cloudvault", "search", "query"),
            ("hermes", "ratchet", "ratchet_chain_kdf"),
            ("pricing", "token-cost", "calculate_token_cost")
        ] {
            let sample = try XCTUnwrap(DomainCoreShadowSampleV3(
                comparison: .init(
                    domain: domain,
                    slice: slice,
                    operation: operation,
                    coreVersion: "0.3.0",
                    outcome: "match",
                    mismatchCategory: nil,
                    legacyMicros: 10,
                    rustMicros: 8
                ),
                channel: "internal",
                candidate: try XCTUnwrap(signedCandidate()),
                loadedIdentity: loadedIdentity
            ))
            XCTAssertEqual(sample.schemaVersion, 3)
            XCTAssertEqual(sample.domain, domain)
            XCTAssertEqual(sample.slice, slice)
            XCTAssertEqual(sample.consumer, "apple")
        }
    }

    func testUnacknowledgedBatchIsReturnedForRetryUntilAcknowledged() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        try spool.append(try XCTUnwrap(makeSample()))

        let first = try XCTUnwrap(spool.nextBatch())
        let retry = try XCTUnwrap(spool.nextBatch())
        XCTAssertEqual(first.token, retry.token)
        XCTAssertEqual(try spool.pendingSampleCount(), 1)

        try spool.acknowledge(retry.token)
        XCTAssertEqual(try spool.pendingSampleCount(), 0)
        XCTAssertNil(try spool.nextBatch())
    }

    func testRapidSamplesCoalesceIntoOneBoundedDelayedUpload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        let submitter = RecordingDomainCoreShadowSubmitter()
        let coordinator = DomainCoreShadowEvidenceUploadCoordinator(
            spool: spool,
            submitter: submitter,
            activeChannel: "internal",
            activeCandidate: try XCTUnwrap(signedCandidate()),
            debounceNanoseconds: 1_000_000_000
        )

        try spool.append(try XCTUnwrap(makeSample(micros: 1)))
        await coordinator.scheduleFlush()
        try await Task.sleep(nanoseconds: 100_000_000)
        try spool.append(try XCTUnwrap(makeSample(micros: 2)))
        await coordinator.scheduleFlush()
        try await Task.sleep(nanoseconds: 100_000_000)

        let earlyBatchSizes = await submitter.batchSizes()
        XCTAssertEqual(earlyBatchSizes, [], "debounce must run from the most recent sample")

        try spool.append(try XCTUnwrap(makeSample(micros: 3)))
        await coordinator.scheduleFlush()
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let batchSizes = await submitter.batchSizes()
        XCTAssertEqual(batchSizes, [3])
        XCTAssertEqual(try spool.pendingSampleCount(), 0)
    }

    func testMalformedReadyFilenameIsDeletedWithoutWedgingQueue() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        try Data("{}\n".utf8).write(to: directory.appendingPathComponent("ready-not-an-ordinal.jsonl"))

        XCTAssertNil(try spool.nextBatch(sealActive: false))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testEmptyAndOversizedReadyBatchesAreDeletedWithoutRetryLoop() throws {
        let emptyDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }
        let emptySpool = try DomainCoreShadowEvidenceSpool(directory: emptyDirectory)
        try Data().write(to: readyURL(in: emptyDirectory, ordinal: 0))

        XCTAssertNil(try emptySpool.nextBatch(sealActive: false))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: emptyDirectory.path).isEmpty)

        let oversizedDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: oversizedDirectory) }
        let oversizedSpool = try DomainCoreShadowEvidenceSpool(
            directory: oversizedDirectory,
            maxSamplesPerFile: 1
        )
        let line = try encodedLine(try XCTUnwrap(makeSample()))
        try (line + line).write(to: readyURL(in: oversizedDirectory, ordinal: 0))

        XCTAssertNil(try oversizedSpool.nextBatch(sealActive: false))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: oversizedDirectory.path).isEmpty)
    }

    func testCorruptAndNonV3OldestFilesCannotBlockValidLaterBatch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        try Data("{not-json}\n".utf8).write(to: readyURL(in: directory, ordinal: 0))
        var nonV3 = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(makeSample()))) as? [String: Any]
        )
        nonV3["schemaVersion"] = 2
        var nonV3Data = try JSONSerialization.data(withJSONObject: nonV3, options: [.sortedKeys])
        nonV3Data.append(0x0A)
        try nonV3Data.write(to: readyURL(in: directory, ordinal: 1))
        try spool.append(try XCTUnwrap(makeSample(micros: 42)))

        let batch = try XCTUnwrap(spool.nextBatch(
            matchingChannel: "internal",
            matchingCandidate: try XCTUnwrap(signedCandidate())
        ))

        XCTAssertEqual(batch.samples.single?.legacyMicros, 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: readyURL(in: directory, ordinal: 0).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: readyURL(in: directory, ordinal: 1).path))
    }

    func testSemanticInvalidRecordsCannotWedgeFreshSiblingInSameReadyFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let candidate = try XCTUnwrap(signedCandidate())
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        let fresh = try XCTUnwrap(makeSample(legacyMicros: 42, observedAt: now))
        let freshData = try JSONEncoder().encode(fresh)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: freshData) as? [String: Any])
        func replacing(_ key: String, with value: Any) -> [String: Any] {
            var object = base
            object[key] = value
            return object
        }
        var extraField = base
        extraField["metadata"] = ["authority": "signed"]
        let invalidObjects: [[String: Any]] = [
            replacing("consumer", with: "android"),
            replacing("operation", with: "codex_quota"),
            replacing("sampleId", with: "not-a-uuid"),
            replacing("candidateCommit", with: String(repeating: "A", count: 40)),
            replacing("expectedCoreVersion", with: "01.0.0"),
            replacing("loadedCoreAbiVersion", with: NSNull()),
            replacing("mismatchCategory", with: "native_error"),
            replacing("legacyMicros", with: 600_000_001),
            replacing("observedAt", with: "2025-01-01T00:00:00.000Z"),
            extraField
        ]
        var readyData = Data()
        for object in invalidObjects + [base] {
            readyData.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            readyData.append(0x0A)
        }
        try readyData.write(to: readyURL(in: directory, ordinal: 0))

        let batch = try XCTUnwrap(spool.nextBatch(
            sealActive: false,
            matchingChannel: "internal",
            matchingCandidate: candidate,
            now: now
        ))

        XCTAssertEqual(batch.samples.map(\.legacyMicros), [42])
        try spool.acknowledge(batch.token)
        XCTAssertEqual(try spool.pendingSampleCount(), 0)
    }

    func testAcknowledgementRejectsNegativeFractionalOverboundAndWrongSumCounts() throws {
        XCTAssertNoThrow(try DomainCoreShadowAcknowledgementValidator.validate(
            ["accepted": 1, "duplicates": 0],
            batchSize: 1
        ))
        for response: [String: Any] in [
            ["accepted": -1, "duplicates": 2],
            ["accepted": 0.5, "duplicates": 0.5],
            ["accepted": 2, "duplicates": 0],
            ["accepted": 0, "duplicates": 0]
        ] {
            XCTAssertThrowsError(try DomainCoreShadowAcknowledgementValidator.validate(response, batchSize: 1))
        }
    }

    func testExpiredAndFutureHeadFilesCannotBlockFreshLaterBatch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        try spool.append(try XCTUnwrap(makeSample(
            legacyMicros: 1,
            observedAt: now.addingTimeInterval(-(31 * 24 * 60 * 60) - 1)
        )))
        try spool.append(try XCTUnwrap(makeSample(
            legacyMicros: 2,
            observedAt: now.addingTimeInterval((5 * 60) + 1)
        )))
        try spool.append(try XCTUnwrap(makeSample(legacyMicros: 42, observedAt: now)))

        let batch = try XCTUnwrap(spool.nextBatch(
            matchingChannel: "internal",
            matchingCandidate: try XCTUnwrap(signedCandidate()),
            now: now
        ))

        XCTAssertEqual(batch.samples.map(\.legacyMicros), [42])
        try spool.acknowledge(batch.token)
        XCTAssertEqual(try spool.pendingSampleCount(), 0)
    }

    func testReadyBatchReadFailurePreservesEvidenceForRetry() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        let url = readyURL(in: directory, ordinal: 0)
        try encodedLine(try XCTUnwrap(makeSample(micros: 42))).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        XCTAssertThrowsError(try spool.nextBatch(sealActive: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let batch = try XCTUnwrap(spool.nextBatch(sealActive: false))
        XCTAssertEqual(batch.samples.single?.legacyMicros, 42)
    }

    func testAppendRejectsSampleLargerThanFileLimitWithoutCreatingEvidence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory, maxFileBytes: 1)

        XCTAssertThrowsError(try spool.append(try XCTUnwrap(makeSample()))) { error in
            guard let evidenceError = error as? DomainCoreShadowEvidenceError,
                  case .oversizedSample = evidenceError else {
                return XCTFail("expected oversizedSample, got \(error)")
            }
        }
        XCTAssertEqual(try spool.pendingSampleCount(), 0)
    }

    func testReadyOrdinalOverflowFailsClosedWithoutReplacingExistingBatch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        let existingURL = readyURL(in: directory, ordinal: UInt64.max)
        try encodedLine(try XCTUnwrap(makeSample(micros: 1))).write(to: existingURL)
        try spool.append(try XCTUnwrap(makeSample(micros: 2)))

        assertInvalidSampleError {
            _ = try spool.nextBatch()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingURL.path))
        XCTAssertEqual(try spool.pendingSampleCount(), 2)
    }

    func testAcknowledgeRejectsUntrustedTokensAndIsIdempotentForMissingValidToken() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)

        for token in [
            "active.jsonl",
            "ready-1.jsonl",
            "ready-0000000000000000000x.jsonl",
            "ready-00000000000000000000.jsonl/../active.jsonl"
        ] {
            assertInvalidSampleError {
                try spool.acknowledge(token)
            }
        }

        XCTAssertNoThrow(try spool.acknowledge("ready-00000000000000000042.jsonl"))
    }

    func testCoordinatorRetriesFailedSubmissionBeforeAcknowledgingBatch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        let submitter = FailOnceDomainCoreShadowSubmitter()
        let coordinator = DomainCoreShadowEvidenceUploadCoordinator(
            spool: spool,
            submitter: submitter,
            activeChannel: "internal",
            activeCandidate: try XCTUnwrap(signedCandidate()),
            debounceNanoseconds: 200_000_000
        )
        try spool.append(try XCTUnwrap(makeSample()))

        await coordinator.flush()

        let attemptsAfterFailure = await submitter.attemptCount()
        XCTAssertEqual(attemptsAfterFailure, 1)
        XCTAssertEqual(try spool.pendingSampleCount(), 1, "failed submission must remain durable")
        try await eventually {
            let attempts = await submitter.attemptCount()
            let pending = try spool.pendingSampleCount()
            return attempts == 2 && pending == 0
        }
        let successfulBatchSizes = await submitter.successfulBatchSizes()
        XCTAssertEqual(successfulBatchSizes, [1])
    }

    func testCoordinatorToleratesSpoolFailureDuringFlushAndPendingRetryCheck() async throws {
        let directory = temporaryDirectory()
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        let coordinator = DomainCoreShadowEvidenceUploadCoordinator(
            spool: spool,
            submitter: RecordingDomainCoreShadowSubmitter(),
            activeChannel: "internal",
            activeCandidate: try XCTUnwrap(signedCandidate())
        )
        try FileManager.default.removeItem(at: directory)

        await coordinator.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMacRecorderOnlyPersistsValidatedSamplesForEnabledChannels() async throws {
        let enabledDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: enabledDirectory) }
        let enabledSubmitter = RecordingDomainCoreShadowSubmitter()
        let enabledRecorder = MacDomainCoreShadowEvidenceRecorder(
            profile: signedProfile(
                profile: "internal",
                distribution: "internal",
                channel: "internal",
                evidenceEnabled: true
            ),
            directory: enabledDirectory,
            submitter: enabledSubmitter,
            debounceNanoseconds: 1_000_000
        )

        enabledRecorder.record(makeComparison(legacyMicros: 1))
        enabledRecorder.record(makeComparison(operation: "unknown_quota", legacyMicros: 2))
        try await eventually {
            await enabledSubmitter.batchSizes() == [1]
        }

        let disabledDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: disabledDirectory) }
        let disabledSubmitter = RecordingDomainCoreShadowSubmitter()
        let disabledRecorder = MacDomainCoreShadowEvidenceRecorder(
            profile: signedProfile(
                profile: "public-production",
                distribution: "public",
                channel: "",
                evidenceEnabled: false,
                quotaMode: "legacy"
            ),
            directory: disabledDirectory,
            submitter: disabledSubmitter,
            debounceNanoseconds: 1_000_000
        )

        disabledRecorder.record(makeComparison(legacyMicros: 3))
        let disabledSpool = try DomainCoreShadowEvidenceSpool(directory: disabledDirectory)
        let disabledBatchSizes = await disabledSubmitter.batchSizes()
        XCTAssertEqual(disabledBatchSizes, [])
        XCTAssertEqual(try disabledSpool.pendingSampleCount(), 0)
        withExtendedLifetime((enabledRecorder, disabledRecorder)) {}
    }

    func testMacRecorderInitializerFlushesDurableApplicationSupportEvidence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        try spool.append(try XCTUnwrap(makeSample()))
        let submitter = RecordingDomainCoreShadowSubmitter()

        let recorder = MacDomainCoreShadowEvidenceRecorder(
            profile: signedProfile(
                profile: "internal",
                distribution: "internal",
                channel: "internal",
                evidenceEnabled: true
            ),
            directory: directory,
            submitter: submitter
        )

        try await eventually {
            let batchSizes = await submitter.batchSizes()
            let pending = try spool.pendingSampleCount()
            return batchSizes == [1] && pending == 0
        }
        withExtendedLifetime(recorder) {}
    }

    func testMacRecorderPublicProfileDiscardsDurableEvidenceWithoutUploading() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory)
        try spool.append(try XCTUnwrap(makeSample(channel: "internal")))
        let submitter = RecordingDomainCoreShadowSubmitter()

        let recorder = MacDomainCoreShadowEvidenceRecorder(
            profile: signedProfile(
                profile: "public-production",
                distribution: "public",
                channel: "",
                evidenceEnabled: false,
                quotaMode: "legacy"
            ),
            directory: directory,
            submitter: submitter,
            debounceNanoseconds: 1_000_000
        )

        try await Task.sleep(nanoseconds: 50_000_000)
        let submittedBatchSizes = await submitter.batchSizes()
        XCTAssertEqual(submittedBatchSizes, [])
        XCTAssertEqual(try spool.pendingSampleCount(), 0)
        withExtendedLifetime(recorder) {}
    }

    func testMacRecorderChannelTransitionDropsStaleSamplesAndUploadsOnlyActiveChannel() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try DomainCoreShadowEvidenceSpool(directory: directory, maxSamplesPerFile: 1)
        try spool.append(try XCTUnwrap(makeSample(channel: "internal", legacyMicros: 1)))
        try spool.append(try XCTUnwrap(makeSample(channel: "beta", legacyMicros: 2)))
        let submitter = RecordingDomainCoreShadowSubmitter()

        let recorder = MacDomainCoreShadowEvidenceRecorder(
            profile: signedProfile(
                profile: "beta",
                distribution: "beta",
                channel: "beta",
                evidenceEnabled: true
            ),
            directory: directory,
            submitter: submitter,
            debounceNanoseconds: 1_000_000
        )

        try await eventually {
            let submittedChannels = await submitter.submittedChannels()
            let pendingSampleCount = try spool.pendingSampleCount()
            return submittedChannels == [["beta"]] && pendingSampleCount == 0
        }
        withExtendedLifetime(recorder) {}
    }

    func testMacRecorderInitializationFailureDisablesRecordingWithoutReplacingFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = Data("not-a-directory".utf8)
        try sentinel.write(to: directory)
        let recorder = MacDomainCoreShadowEvidenceRecorder(
            profile: signedProfile(
                profile: "internal",
                distribution: "internal",
                channel: "internal",
                evidenceEnabled: true
            ),
            directory: directory,
            submitter: RecordingDomainCoreShadowSubmitter()
        )

        recorder.record(makeComparison())

        XCTAssertEqual(try Data(contentsOf: directory), sentinel)
    }

    func testMacRecorderHandlesSpoolDisappearingBeforeRecord() async throws {
        let directory = temporaryDirectory()
        let recorder = MacDomainCoreShadowEvidenceRecorder(
            profile: signedProfile(
                profile: "internal",
                distribution: "internal",
                channel: "internal",
                evidenceEnabled: true
            ),
            directory: directory,
            submitter: RecordingDomainCoreShadowSubmitter(),
            debounceNanoseconds: 1_000_000
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        try FileManager.default.removeItem(at: directory)

        recorder.record(makeComparison())

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeSample(
        channel: String = "internal",
        operation: String = "claude_quota",
        outcome: DomainCoreQuotaShadowOutcome = .match,
        mismatchCategory: DomainCoreQuotaShadowMismatchCategory? = nil,
        legacyMicros: UInt64 = 120,
        rustMicros: UInt64 = 80,
        observedAt: Date = Date(),
        candidate: DomainCoreCandidateIdentity? = nil,
        loadedIdentity: DomainCoreEvidenceLoadedIdentity? = nil,
        loadedIdentityAvailable: Bool = true
    ) -> DomainCoreShadowSampleV3? {
        DomainCoreShadowSampleV3(
            comparison: makeComparison(
                operation: operation,
                outcome: outcome,
                mismatchCategory: mismatchCategory,
                legacyMicros: legacyMicros,
                rustMicros: rustMicros,
                observedAt: observedAt
            ),
            channel: channel,
            candidate: candidate ?? signedCandidate()!,
            loadedIdentity: !loadedIdentityAvailable
                ? nil
                : (loadedIdentity ?? self.loadedIdentity)
        )
    }

    private func makeSample(micros: UInt64) -> DomainCoreShadowSampleV3? {
        makeSample(legacyMicros: micros)
    }

    private func makeComparison(
        operation: String = "claude_quota",
        outcome: DomainCoreQuotaShadowOutcome = .match,
        mismatchCategory: DomainCoreQuotaShadowMismatchCategory? = nil,
        legacyMicros: UInt64 = 120,
        rustMicros: UInt64 = 80,
        observedAt: Date = Date()
    ) -> DomainCoreQuotaShadowComparison {
        DomainCoreQuotaShadowComparison(
            operation: operation,
            coreVersion: "0.3.0",
            observedAt: observedAt,
            outcome: outcome,
            mismatchCategory: mismatchCategory,
            legacyMicros: legacyMicros,
            rustMicros: rustMicros
        )
    }

    private func encodedLine(_ sample: DomainCoreShadowSampleV3) throws -> Data {
        var data = try JSONEncoder().encode(sample)
        data.append(0x0A)
        return data
    }

    private func readyURL(in directory: URL, ordinal: UInt64) -> URL {
        directory.appendingPathComponent(
            "ready-\(String(format: "%020llu", ordinal)).jsonl",
            isDirectory: false
        )
    }

    private func assertInvalidSampleError(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let evidenceError = error as? DomainCoreShadowEvidenceError,
                  case .invalidSample = evidenceError else {
                return XCTFail("expected invalidSample, got \(error)", file: file, line: line)
            }
        }
    }

    private func eventually(
        timeout: TimeInterval = 2,
        operation: @escaping () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await operation() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition was not satisfied before timeout")
    }

    private func signedProfile(
        profile: String,
        distribution: String,
        channel: String,
        evidenceEnabled: Bool,
        quotaMode: String = "shadow",
        candidateCommit: String? = nil
    ) -> DomainCoreBuildProfile {
        DomainCoreBuildProfileResolver.current(environment: [:], info: [
            "OpenBurnBarDomainCoreBuildAuthority": "signed",
            "OpenBurnBarDomainCoreBuildProfile": profile,
            "OpenBurnBarDomainCoreDistribution": distribution,
            "OpenBurnBarDomainCoreRolloutChannel": channel,
            "OpenBurnBarDomainCoreEvidenceEnabled": evidenceEnabled,
            "OpenBurnBarDomainCoreCandidateCommit": candidateCommit ?? self.candidateCommit,
            "OpenBurnBarDomainCoreExpectedVersion": "0.3.0",
            "OpenBurnBarDomainCoreExpectedABIVersion": "3",
            "OpenBurnBarDomainCoreExpectedSourceSHA256": sourceSha256,
            "OpenBurnBarDomainCoreModeQuota": quotaMode,
            "OpenBurnBarDomainCoreModeCloudVault": "legacy",
            "OpenBurnBarDomainCoreModeCloudVaultRewrap": "legacy",
            "OpenBurnBarDomainCoreModeCloudVaultSearch": "legacy",
            "OpenBurnBarDomainCoreModeHermes": "legacy",
            "OpenBurnBarDomainCoreModePricing": "legacy"
        ])
    }

    private func signedCandidate(commit: String? = nil) -> DomainCoreCandidateIdentity? {
        signedProfile(
            profile: "internal",
            distribution: "internal",
            channel: "internal",
            evidenceEnabled: true,
            candidateCommit: commit
        ).candidateIdentity
    }

    private var loadedIdentity: DomainCoreEvidenceLoadedIdentity {
        DomainCoreEvidenceLoadedIdentity(coreVersion: "0.3.0", abiVersion: 3, sourceSha256: sourceSha256)
    }

    private var candidateCommit: String { String(repeating: "a", count: 40) }
    private var sourceSha256: String { String(repeating: "b", count: 64) }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-shadow-\(UUID().uuidString)", isDirectory: true)
    }
}

private actor RecordingDomainCoreShadowSubmitter: DomainCoreShadowSampleSubmitting {
    private var sizes: [Int] = []
    private var channels: [[String]] = []

    func submit(_ samples: [DomainCoreShadowSampleV3]) async throws {
        sizes.append(samples.count)
        channels.append(samples.map(\.channel))
    }

    func batchSizes() -> [Int] { sizes }
    func submittedChannels() -> [[String]] { channels }
}

private actor FailOnceDomainCoreShadowSubmitter: DomainCoreShadowSampleSubmitting {
    private var attempts = 0
    private var successes: [Int] = []

    func submit(_ samples: [DomainCoreShadowSampleV3]) async throws {
        attempts += 1
        if attempts == 1 {
            throw Failure.rejected
        }
        successes.append(samples.count)
    }

    func attemptCount() -> Int { attempts }
    func successfulBatchSizes() -> [Int] { successes }

    private enum Failure: Error {
        case rejected
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
