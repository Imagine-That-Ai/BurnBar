import XCTest
@testable import OpenBurnBar

/// U5: pure routing table for usage-memory curation.
///
/// Invariants under test:
///  - **Dormancy fail-safe:** `extractionEnabled == false` always routes
///    `.queueOnly`, whatever else the snapshot claims.
///  - **Local placement:** never produces a cloud route; images go to the local
///    VL model when configured, are stripped to `.localText` otherwise, and an
///    unprovisioned local chain queues.
///  - **Cloud gating:** cloud placements require BOTH the cloud-curation gate
///    and client budget headroom; either missing falls back to the local chain.
///  - **Server exhaustion fallbacks:** burnbarCloud degrades multimodal → text
///    → local chain → queue; cloudText degrades text → local chain → queue.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
final class UsageMemoryModelRouterTests: XCTestCase {

    /// Fully-provisioned baseline: every lever open, every model available.
    /// Individual tests switch levers OFF from here.
    private func snapshot(
        placement: UsageMemoryModelPlacement,
        extractionEnabled: Bool = true,
        cloudCurationEnabled: Bool = true,
        localTextModelAvailable: Bool = true,
        localVLModelAvailable: Bool = true,
        cloudBudgetOK: Bool = true,
        serverTextExhausted: Bool = false,
        serverMultimodalExhausted: Bool = false
    ) -> UsageMemoryModelRouter.Snapshot {
        UsageMemoryModelRouter.Snapshot(
            placement: placement,
            extractionEnabled: extractionEnabled,
            cloudCurationEnabled: cloudCurationEnabled,
            localTextModelAvailable: localTextModelAvailable,
            localVLModelAvailable: localVLModelAvailable,
            cloudBudgetOK: cloudBudgetOK,
            serverTextExhausted: serverTextExhausted,
            serverMultimodalExhausted: serverMultimodalExhausted
        )
    }

    // MARK: - Dormant fail-safe

    func testDormantExtractionAlwaysQueuesRegardlessOfEverythingElse() {
        // Callers should never reach the router while dormant, but the router
        // itself must fail safe for EVERY placement and image combination.
        for placement in UsageMemoryModelPlacement.allCases {
            for hasImages in [false, true] {
                XCTAssertEqual(
                    UsageMemoryModelRouter.route(
                        snapshot: snapshot(placement: placement, extractionEnabled: false),
                        hasImageContent: hasImages
                    ),
                    .queueOnly,
                    "placement=\(placement) hasImages=\(hasImages)"
                )
            }
        }
    }

    // MARK: - Local placement

    func testLocalTextBatchRoutesToLocalText() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(snapshot: snapshot(placement: .local), hasImageContent: false),
            .localText
        )
    }

    func testLocalImageBatchRoutesToLocalMultimodalWhenVLModelAvailable() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(snapshot: snapshot(placement: .local), hasImageContent: true),
            .localMultimodal
        )
    }

    func testLocalImageBatchStripsToLocalTextWithoutVLModel() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .local, localVLModelAvailable: false),
                hasImageContent: true
            ),
            .localText,
            "No VL model: images are STRIPPED and the text model curates the text."
        )
    }

    func testLocalImageBatchUsesVLModelEvenWithoutTextModel() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .local, localTextModelAvailable: false),
                hasImageContent: true
            ),
            .localMultimodal,
            "The VL model alone can serve an image batch."
        )
    }

    func testLocalPlacementQueuesWhenNoLocalModelFitsTheBatch() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .local, localTextModelAvailable: false, localVLModelAvailable: false),
                hasImageContent: true
            ),
            .queueOnly
        )
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .local, localTextModelAvailable: false),
                hasImageContent: false
            ),
            .queueOnly,
            "A text batch cannot fall onto the VL model; without a text model it queues."
        )
    }

    func testLocalPlacementNeverRoutesToCloudEvenFullyProvisioned() {
        // Cloud gate open + budget OK must be irrelevant under .local placement.
        for hasImages in [false, true] {
            let route = UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .local),
                hasImageContent: hasImages
            )
            XCTAssertNotEqual(route, .burnbarCloudText)
            XCTAssertNotEqual(route, .burnbarCloudMultimodal)
        }
    }

    // MARK: - burnbarCloud placement (happy paths)

    func testBurnbarCloudImageBatchPrefersMultimodalLane() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(snapshot: snapshot(placement: .burnbarCloud), hasImageContent: true),
            .burnbarCloudMultimodal
        )
    }

    func testBurnbarCloudTextBatchUsesTextLane() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(snapshot: snapshot(placement: .burnbarCloud), hasImageContent: false),
            .burnbarCloudText
        )
    }

    // MARK: - burnbarCloud exhaustion chain

    func testBurnbarCloudMultimodalExhaustedDegradesToTextLane() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .burnbarCloud, serverMultimodalExhausted: true),
                hasImageContent: true
            ),
            .burnbarCloudText,
            "Multimodal allowance spent but text lane still OK: images strip to the text lane."
        )
    }

    func testBurnbarCloudBothLanesExhaustedFallsBackToLocalVL() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(
                    placement: .burnbarCloud,
                    serverTextExhausted: true,
                    serverMultimodalExhausted: true
                ),
                hasImageContent: true
            ),
            .localMultimodal
        )
    }

    func testBurnbarCloudBothLanesExhaustedFallsBackToLocalTextWithoutVL() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(
                    placement: .burnbarCloud,
                    localVLModelAvailable: false,
                    serverTextExhausted: true,
                    serverMultimodalExhausted: true
                ),
                hasImageContent: true
            ),
            .localText
        )
    }

    func testBurnbarCloudTextExhaustedTextBatchFallsBackToLocalText() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .burnbarCloud, serverTextExhausted: true),
                hasImageContent: false
            ),
            .localText
        )
    }

    func testBurnbarCloudFullyExhaustedAndNoLocalModelsQueues() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(
                    placement: .burnbarCloud,
                    localTextModelAvailable: false,
                    localVLModelAvailable: false,
                    serverTextExhausted: true,
                    serverMultimodalExhausted: true
                ),
                hasImageContent: true
            ),
            .queueOnly
        )
    }

    func testBurnbarCloudTextExhaustionDoesNotBlockMultimodalLane() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .burnbarCloud, serverTextExhausted: true),
                hasImageContent: true
            ),
            .burnbarCloudMultimodal,
            "The lanes meter independently: a text exhaustion must not stop image batches."
        )
    }

    // MARK: - cloudText placement

    func testCloudTextPlacementUsesTextLane() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(snapshot: snapshot(placement: .cloudText), hasImageContent: false),
            .burnbarCloudText
        )
    }

    func testCloudTextPlacementStripsImagesToTextLane() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(snapshot: snapshot(placement: .cloudText), hasImageContent: true),
            .burnbarCloudText,
            "cloudText placement never uses the multimodal lane; images strip."
        )
    }

    func testCloudTextPlacementNeverRoutesMultimodalEvenWhenMultimodalLaneOpen() {
        XCTAssertNotEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .cloudText, serverMultimodalExhausted: false),
                hasImageContent: true
            ),
            .burnbarCloudMultimodal
        )
    }

    func testCloudTextExhaustedFallsBackToLocalChain() {
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .cloudText, serverTextExhausted: true),
                hasImageContent: false
            ),
            .localText
        )
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(placement: .cloudText, serverTextExhausted: true),
                hasImageContent: true
            ),
            .localMultimodal,
            "The local fallback re-attaches images when the VL model exists."
        )
        XCTAssertEqual(
            UsageMemoryModelRouter.route(
                snapshot: snapshot(
                    placement: .cloudText,
                    localTextModelAvailable: false,
                    localVLModelAvailable: false,
                    serverTextExhausted: true
                ),
                hasImageContent: false
            ),
            .queueOnly
        )
    }

    // MARK: - Cloud gate / client budget fallbacks (both cloud placements)

    func testCloudPlacementsFallBackToLocalWhenCloudGateClosed() {
        for placement in [UsageMemoryModelPlacement.cloudText, .burnbarCloud] {
            XCTAssertEqual(
                UsageMemoryModelRouter.route(
                    snapshot: snapshot(placement: placement, cloudCurationEnabled: false),
                    hasImageContent: false
                ),
                .localText,
                "placement=\(placement)"
            )
            XCTAssertEqual(
                UsageMemoryModelRouter.route(
                    snapshot: snapshot(placement: placement, cloudCurationEnabled: false),
                    hasImageContent: true
                ),
                .localMultimodal,
                "placement=\(placement)"
            )
        }
    }

    func testCloudPlacementsFallBackToLocalWhenClientBudgetSpent() {
        for placement in [UsageMemoryModelPlacement.cloudText, .burnbarCloud] {
            XCTAssertEqual(
                UsageMemoryModelRouter.route(
                    snapshot: snapshot(placement: placement, cloudBudgetOK: false),
                    hasImageContent: false
                ),
                .localText,
                "placement=\(placement)"
            )
        }
    }

    func testCloudPlacementsQueueWhenGateClosedAndNoLocalModels() {
        for placement in [UsageMemoryModelPlacement.cloudText, .burnbarCloud] {
            for hasImages in [false, true] {
                XCTAssertEqual(
                    UsageMemoryModelRouter.route(
                        snapshot: snapshot(
                            placement: placement,
                            cloudCurationEnabled: false,
                            localTextModelAvailable: false,
                            localVLModelAvailable: false
                        ),
                        hasImageContent: hasImages
                    ),
                    .queueOnly,
                    "placement=\(placement) hasImages=\(hasImages)"
                )
            }
        }
    }

    // MARK: - Exhaustive sweep: closed cloud gate never yields a cloud route

    func testNoCloudRouteEverEscapesAClosedCloudGateOrSpentBudget() {
        // Sweep every boolean combination with the cloud gate or budget closed:
        // a cloud route must be impossible, whatever the placement/exhaustion.
        for placement in UsageMemoryModelPlacement.allCases {
            for localText in [false, true] {
                for localVL in [false, true] {
                    for textExhausted in [false, true] {
                        for multimodalExhausted in [false, true] {
                            for hasImages in [false, true] {
                                for (gate, budget) in [(false, true), (true, false), (false, false)] {
                                    let route = UsageMemoryModelRouter.route(
                                        snapshot: snapshot(
                                            placement: placement,
                                            cloudCurationEnabled: gate,
                                            localTextModelAvailable: localText,
                                            localVLModelAvailable: localVL,
                                            cloudBudgetOK: budget,
                                            serverTextExhausted: textExhausted,
                                            serverMultimodalExhausted: multimodalExhausted
                                        ),
                                        hasImageContent: hasImages
                                    )
                                    XCTAssertFalse(
                                        route == .burnbarCloudText || route == .burnbarCloudMultimodal,
                                        "Cloud route leaked: placement=\(placement) gate=\(gate) budget=\(budget) hasImages=\(hasImages)"
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
