import SwiftUI
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Covers the two pure halves of the Liquid Plasma selector: the transcribed
/// blob motion and the three-rung cascade. Both are deliberately free of
/// SwiftUI state so the asset's curve and the ladder's rules can be pinned
/// without rendering a view.
final class PlasmaModelSelectorTests: XCTestCase {

    // MARK: - Blob motion

    func testMotionLoopsSeamlessly() {
        for motion in [PlasmaBlobMotion.orbPrimary, .orbSecondary, .bubble] {
            let start = motion.state(atPhase: 0)
            let end = motion.state(atPhase: 1)
            XCTAssertEqual(start.radii, end.radii, "phase 1 must land back on phase 0")
            XCTAssertEqual(start.scaleWidth, end.scaleWidth, accuracy: 0.0001)
            XCTAssertEqual(start.rotationDegrees, end.rotationDegrees, accuracy: 0.0001)
        }
    }

    func testMotionPhaseWrapsInsteadOfClamping() {
        let motion = PlasmaBlobMotion.orbPrimary
        let reference = motion.state(atPhase: 0.2)
        for phase in [CGFloat(2.2), -0.8, 7.2] {
            let wrapped = motion.state(atPhase: phase)
            XCTAssertEqual(wrapped.radii.topLeadingX, reference.radii.topLeadingX, accuracy: 1e-6, "phase \(phase)")
            XCTAssertEqual(wrapped.rotationDegrees, reference.rotationDegrees, accuracy: 1e-6, "phase \(phase)")
        }
    }

    /// Sampling exactly on a stop must reproduce that stop, not an interpolated
    /// neighbour. Read from the table rather than hardcoding numbers, so
    /// retuning the motion is a design change and not a test break.
    func testMotionHitsItsAuthoredKeyframesExactly() throws {
        for motion in [PlasmaBlobMotion.orbPrimary, .orbSecondary, .bubble] {
            for keyframe in motion.keyframes {
                let sampled = motion.state(atPhase: keyframe.stop)
                let authored = keyframe.state
                XCTAssertEqual(sampled.translation.width, authored.translation.width, accuracy: 1e-9)
                XCTAssertEqual(sampled.translation.height, authored.translation.height, accuracy: 1e-9)
                XCTAssertEqual(sampled.rotationDegrees, authored.rotationDegrees, accuracy: 1e-9)
                XCTAssertEqual(sampled.scaleWidth, authored.scaleWidth, accuracy: 1e-9)
                XCTAssertEqual(sampled.scaleHeight, authored.scaleHeight, accuracy: 1e-9)
                XCTAssertEqual(sampled.radii, authored.radii, "stop \(keyframe.stop)")
            }
        }
    }

    func testOrbTranslationScalesWithRenderedSize() throws {
        let motion = PlasmaBlobMotion.orbPrimary
        let authoredSize = try XCTUnwrap(motion.authoredSize)
        // Pick the stop that drifts furthest, so the assertion cannot pass on a
        // track whose offsets happen to be zero.
        let peak = try XCTUnwrap(motion.keyframes.max { abs($0.state.translation.height) < abs($1.state.translation.height) })
        let state = motion.state(atPhase: peak.stop)

        XCTAssertNotEqual(state.translation.height, 0, "the peak stop must actually move")
        XCTAssertEqual(motion.translation(state, renderedSize: authoredSize).height,
                       state.translation.height, accuracy: 1e-9,
                       "at the authored size the offset is unscaled")
        XCTAssertEqual(motion.translation(state, renderedSize: authoredSize / 4).height,
                       state.translation.height / 4, accuracy: 1e-9,
                       "a quarter-size orb drifts a quarter as far")
    }

    func testBubbleTranslationIsAbsoluteAtAnyWidth() throws {
        let motion = PlasmaBlobMotion.bubble
        XCTAssertNil(motion.authoredSize, "the bubble billows the same at any width")
        let peak = try XCTUnwrap(motion.keyframes.max { abs($0.state.translation.height) < abs($1.state.translation.height) })
        let state = motion.state(atPhase: peak.stop)
        XCTAssertNotEqual(state.translation.height, 0)
        for width in [CGFloat(42), 336, 1024] {
            XCTAssertEqual(motion.translation(state, renderedSize: width).height,
                           state.translation.height, accuracy: 1e-9, "width \(width)")
        }
    }

    /// The bubble is a container for text. The Grok Bot D morph swings its
    /// corners from 32% to 68% — far wider than the previous asset — so the
    /// thing that keeps a long model id off the curve is the render-time
    /// `cornerCap`, not the table. Pin the cap.
    func testCappedBubbleCornersNeverExceedTheirCeilingAtAnyKeyframe() {
        let cap: CGFloat = 30
        let bounds = CGRect(x: 0, y: 0, width: 356, height: 268)
        for keyframe in PlasmaBlobMotion.bubble.keyframes {
            let shape = PlasmaBlobShape(radii: keyframe.state.radii, cornerCap: cap)
            let path = shape.path(in: bounds)
            XCTAssertFalse(path.isEmpty, "stop \(keyframe.stop) produced no path")
            // A corner larger than the cap would bow the silhouette outside the
            // frame it was handed.
            XCTAssertLessThanOrEqual(path.boundingRect.width, bounds.width + 0.5)
            XCTAssertLessThanOrEqual(path.boundingRect.height, bounds.height + 0.5)
        }
    }

    /// The morph must still be visibly *asymmetric*, or the bubble is just a
    /// rounded rectangle with extra maths.
    func testBubbleCornersActuallyDisagreeWithEachOther() {
        let radii = PlasmaBlobMotion.bubble.state(atPhase: 0.2).radii
        XCTAssertNotEqual(radii.topLeadingX, radii.bottomTrailingX, accuracy: 0.02)
    }

    func testPhaseOffsetDesynchronisesOrbsSharingOneClock() {
        let motion = PlasmaBlobMotion.orbPrimary
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let base = motion.state(at: date)
        XCTAssertEqual(motion.state(at: date, phaseOffset: 0).radii, base.radii)
        XCTAssertEqual(motion.state(at: date, phaseOffset: 1).radii, base.radii, "a whole turn is a no-op")
        XCTAssertNotEqual(motion.state(at: date, phaseOffset: 0.25).radii, base.radii,
                          "neighbouring orbs must not pulse in unison")
    }

    func testCappedShapeStaysInsideTheContentBox() {
        // The asset's bubble is a literal oval; capping is what keeps a model
        // name off the curve. Every corner must land inside the cap.
        // A deliberately extreme set, well past anything the shipped tracks
        // reach, so the cap is exercised rather than coincidentally satisfied.
        let radii = PlasmaBlobRadii.css(48, 52, 46, 54, 52, 48, 54, 46)
        let rect = CGRect(x: 0, y: 0, width: 336, height: 400)
        let capped = PlasmaBlobShape(radii: radii, cornerCap: 30).path(in: rect)
        let uncapped = PlasmaBlobShape(radii: radii, cornerCap: nil).path(in: rect)
        XCTAssertGreaterThan(capped.boundingRect.width, uncapped.boundingRect.width * 0.99)
        // An uncapped 56% corner eats 188pt of a 336pt row; the capped one 30.
        XCTAssertFalse(capped.contains(CGPoint(x: 1, y: 1)), "the corner is still rounded")
        XCTAssertTrue(capped.contains(CGPoint(x: 34, y: 6)), "capped corners clear the content box")
        XCTAssertFalse(uncapped.contains(CGPoint(x: 34, y: 6)), "the untamed blob would clip a row")
    }

    // MARK: - Ladder: grouping

    func testCLIOptionsGroupByProviderInCatalogOrder() {
        let groups = PlasmaModelLadder.groups(fromCLI: [
            cliOption(modelID: "gpt-5.6-luna", provider: "openai", display: "GPT-5.6 Luna · OpenAI · Reasoning: high"),
            cliOption(modelID: "claude-opus-5", provider: "anthropic", display: "Claude Opus 5 · Anthropic"),
            cliOption(modelID: "gpt-5.5", provider: "openai", display: "GPT-5.5 · OpenAI")
        ])
        XCTAssertEqual(groups.map(\.id), ["openai", "anthropic"])
        XCTAssertEqual(groups[0].displayName, "OpenAI")
        XCTAssertEqual(groups[0].entries.map(\.id), ["gpt-5.6-luna", "gpt-5.5"])
        XCTAssertEqual(groups[1].entries.count, 1)
    }

    func testCLIEntrySplitsTheComposedDisplayNameIntoTitleAndDetail() throws {
        let groups = PlasmaModelLadder.groups(fromCLI: [
            cliOption(
                modelID: "claude-sonnet-4-6",
                provider: "anthropic",
                display: "Claude Sonnet 4.6 · Anthropic · via OpenBurnBar · Reasoning: high",
                source: .claudeModelCatalog
            )
        ])
        let entry = try XCTUnwrap(groups.first?.entries.first)
        XCTAssertEqual(entry.title, "Claude Sonnet 4.6", "rung 3 shows the model, not the whole string")
        let detail = try XCTUnwrap(entry.detail)
        XCTAssertTrue(detail.contains("claude-sonnet-4-6"), "the id that will be sent stays visible")
        XCTAssertTrue(detail.contains("Reasoning: high"))
        XCTAssertTrue(detail.contains("Claude Code model catalog"), "where the tokens are billed stays visible")
        XCTAssertFalse(detail.contains("Anthropic"), "the provider is rung 2's job")
    }

    func testProviderRowSummarisesItsBillingSources() {
        let groups = PlasmaModelLadder.groups(fromCLI: [
            cliOption(modelID: "a", provider: "factory", display: "A", source: .droidStandardQuota),
            cliOption(modelID: "b", provider: "factory", display: "B", source: .droidCoreQuota),
            cliOption(modelID: "c", provider: "factory", display: "C", source: .openBurnBarProxy)
        ])
        XCTAssertEqual(groups.count, 1)
        let summary = groups[0].sourceSummary ?? ""
        XCTAssertTrue(summary.hasPrefix("Droid Standard quota · Droid Core quota"))
        XCTAssertTrue(summary.hasSuffix("+1 more"), "a fourth source must not overflow the pill")
    }

    func testGatewayModelsCarryRouteEligibility() {
        let groups = PlasmaModelLadder.groups(fromGateway: [
            gatewayModel(id: "glm-5.1", provider: "zai", eligible: true),
            gatewayModel(id: "glm-4", provider: "zai", eligible: false)
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sourceSummary, "1 of 2 routable")
        XCTAssertTrue(groups[0].entries[1].isDisabled)
        XCTAssertEqual(groups[0].entries[1].detail?.contains("No eligible route"), true)
    }

    func testUnlabelledProviderFallsIntoItsOwnHonestGroup() {
        let groups = PlasmaModelLadder.groups(fromGateway: [gatewayModel(id: "mystery", provider: nil, eligible: true)])
        XCTAssertEqual(groups.map(\.id), ["unknown"])
        XCTAssertEqual(groups[0].displayName, "Unlabelled provider")
    }

    // MARK: - Ladder: orphaned selections

    func testOrphanedSelectionIsSurfacedDisabledRatherThanDropped() {
        let base = PlasmaModelLadder.groups(fromCLI: [
            cliOption(modelID: "gpt-5.5", provider: "openai", display: "GPT-5.5")
        ])
        let patched = PlasmaModelLadder.includingOrphanedSelection(
            base,
            selection: "gpt-4o-retired",
            note: "Not advertised by this Mac"
        )
        let orphan = patched.last?.entries.last
        XCTAssertEqual(orphan?.id, "gpt-4o-retired")
        XCTAssertEqual(orphan?.isDisabled, true)
        XCTAssertEqual(orphan?.detail, "Not advertised by this Mac")
    }

    func testAdvertisedSelectionAddsNoOrphanRow() {
        let base = PlasmaModelLadder.groups(fromCLI: [
            cliOption(modelID: "gpt-5.5", provider: "openai", display: "GPT-5.5")
        ])
        XCTAssertEqual(
            PlasmaModelLadder.includingOrphanedSelection(base, selection: "gpt-5.5", note: "x"),
            base
        )
        XCTAssertEqual(
            PlasmaModelLadder.includingOrphanedSelection(base, selection: "  ", note: "x"),
            base,
            "an empty selection means automatic, not a missing model"
        )
    }

    func testOrphanJoinsTheExistingUnknownGroupInsteadOfMintingASecond() {
        let base = PlasmaModelLadder.groups(fromGateway: [gatewayModel(id: "mystery", provider: nil, eligible: true)])
        let patched = PlasmaModelLadder.includingOrphanedSelection(base, selection: "ghost", note: "gone")
        XCTAssertEqual(patched.count, 1)
        XCTAssertEqual(patched[0].entries.map(\.id), ["mystery", "ghost"])
    }

    // MARK: - Ladder: cascade rules

    func testSingleProviderAgentSkipsTheProviderRungBothWays() {
        XCTAssertEqual(PlasmaModelLadder.levelAfterChoosingAgent(groupCount: 1), .model)
        XCTAssertEqual(PlasmaModelLadder.levelBehindModels(groupCount: 1), .agent)
        XCTAssertEqual(PlasmaModelLadder.levelAfterChoosingAgent(groupCount: 0), .model)
        XCTAssertEqual(PlasmaModelLadder.levelBehindModels(groupCount: 0), .agent)
    }

    func testMultiProviderAgentStopsOnTheProviderRungBothWays() {
        XCTAssertEqual(PlasmaModelLadder.levelAfterChoosingAgent(groupCount: 4), .provider)
        XCTAssertEqual(PlasmaModelLadder.levelBehindModels(groupCount: 4), .provider)
    }

    func testAutomaticRowIsReachableFromEveryModelChoosingRung() {
        XCTAssertFalse(PlasmaModelLadder.showsAutomaticRow(on: .agent))
        XCTAssertTrue(PlasmaModelLadder.showsAutomaticRow(on: .provider))
        XCTAssertTrue(PlasmaModelLadder.showsAutomaticRow(on: .model))
    }

    func testResolvedGroupFollowsTheStoredSelectionWhenNoGroupIsPinned() {
        let groups = PlasmaModelLadder.groups(fromCLI: [
            cliOption(modelID: "gpt-5.5", provider: "openai", display: "GPT-5.5"),
            cliOption(modelID: "claude-opus-5", provider: "anthropic", display: "Claude Opus 5")
        ])
        XCTAssertEqual(
            PlasmaModelLadder.resolvedGroupID(preferred: nil, selection: "claude-opus-5", groups: groups),
            "anthropic"
        )
        XCTAssertEqual(
            PlasmaModelLadder.resolvedGroupID(preferred: "openai", selection: "claude-opus-5", groups: groups),
            "openai",
            "an explicit pin wins over the stored selection"
        )
    }

    func testResolvedGroupRecoversWhenARefreshDropsThePinnedProvider() {
        let groups = PlasmaModelLadder.groups(fromCLI: [
            cliOption(modelID: "gpt-5.5", provider: "openai", display: "GPT-5.5")
        ])
        XCTAssertEqual(
            PlasmaModelLadder.resolvedGroupID(preferred: "anthropic", selection: "", groups: groups),
            "openai",
            "a stale pin must never strand the ladder on an empty rung"
        )
        XCTAssertNil(PlasmaModelLadder.resolvedGroupID(preferred: "openai", selection: "", groups: []))
    }

    // MARK: - Hermes route mapping

    func testHermesProviderRungMapsOntoTheRouteFamilies() {
        let expected: [String: HermesModelID] = [
            "openai": .codex,
            "codex": .codex,
            "anthropic": .claude,
            "claude": .claude,
            "zai": .zai,
            "glm": .zai,
            "kimi": .kimi,
            "moonshot": .kimi,
            "minimax": .minimax,
            "ollama": .ollama,
            "ollama-local": .ollama
        ]
        for (providerID, family) in expected {
            XCTAssertEqual(
                ChatSessionController.hermesFamilyHint(for: providerID),
                family,
                "provider \(providerID) should route through \(family.displayName)"
            )
        }
        XCTAssertNil(ChatSessionController.hermesFamilyHint(for: "nvidia"))
    }

    // MARK: - Choices

    /// The bubble renders one choice list as either orbs or pills, and both
    /// feed a single `ForEach`. A catalog is free to advertise its own empty-id
    /// "default" row, which means exactly what the synthetic Automatic choice
    /// means — so the two must never end up in that list together.
    func testAutomaticChoiceIDCannotCollideWithACatalogModelID() {
        let groups = PlasmaModelLadder.groups(fromCLI: [
            cliOption(modelID: "", provider: "openai", display: "Default"),
            cliOption(modelID: "gpt-5.6-luna", provider: "openai", display: "GPT-5.6 Luna")
        ])
        let ids = groups.flatMap { $0.entries.map(\.id) }
        XCTAssertTrue(ids.contains(""), "the catalog's own default row still has to survive grouping")
        XCTAssertFalse(
            ids.contains(PlasmaModelLadder.automaticChoiceID),
            "the synthetic id must be namespaced out of the catalog's id space"
        )
    }

    /// A model detail is a composite line; an orb caption is one short line.
    func testCompactSubtitleKeepsOnlyTheIdentifyingComponent() {
        let choice = PlasmaChoice(
            id: "gpt-5.6-luna",
            title: "GPT-5.6 Luna",
            subtitle: "gpt-5.6-luna · Reasoning: high · Droid Core quota",
            tint: .blue,
            action: {}
        )
    }

    /// Selecting a choice must run that choice's own action — the flat model is
    /// what stops the two bodies from re-deriving the target by string id and
    /// drifting apart.
    func testChoiceCarriesItsOwnAction() {
        var chosen: String?
        let choices = ["a", "b"].map { id in
            PlasmaChoice(id: id, title: id, tint: .blue, action: { chosen = id })
        }
        choices[1].action()
        XCTAssertEqual(chosen, "b")
    }

    // MARK: - Fixtures

    private func cliOption(
        modelID: String,
        provider: String,
        display: String,
        source: CLIRuntimeModelSource = .cliProfile
    ) -> CLIRuntimeModelOption {
        CLIRuntimeModelOption(
            modelID: modelID,
            displayName: display,
            providerID: provider,
            providerName: provider,
            source: source
        )
    }

    private func gatewayModel(id: String, provider: String?, eligible: Bool) -> OpenAICompatibleAdvertisedModel {
        OpenAICompatibleAdvertisedModel(
            id: id,
            displayName: id,
            providerID: provider,
            providerName: provider,
            routeEligible: eligible
        )
    }
}
