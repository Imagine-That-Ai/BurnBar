import Foundation
import OpenBurnBarCore

/// Routes the recap's editorial pass through whichever chat backend the user has
/// already connected — local-first, exactly as the Charts insight strip does.
///
/// Returning nil is a normal outcome, not a failure: with no backend connected
/// the deterministic recap is already complete, and the composer simply seals it
/// on its own copy.
struct MacRecapVoiceAuthor: RecapVoiceAuthor {

    let bridge: CLIBridge
    let enabledBackends: [ChatBackendID]

    func author(_ request: RecapVoiceRequest) async throws -> RecapVoiceAuthorResult? {
        // `CLIOneShotChat` is main-actor isolated; this method is not.
        let candidates = await CLIOneShotChat.candidates(from: enabledBackends)
        guard !candidates.isEmpty else { return nil }

        // The composer owns retrying with a "JSON only" reminder, so one prompt
        // per call here. A longer ceiling than the Charts strip: the recap
        // payload is larger and this runs in the background behind a deck the
        // user is already reading.
        let answer = await CLIOneShotChat.firstAnswer(
            backends: candidates,
            bridge: bridge,
            systemPrompt: request.systemPrompt,
            attempts: [request.userPrompt],
            timeout: 150
        ) { text in
            RecapJSON.extractFirstObject(from: text) != nil
        }

        guard let answer else { return nil }
        return RecapVoiceAuthorResult(text: answer.text, modelTag: Self.tag(for: answer.backend))
    }

    /// Where the words came from, and whether the numbers left the device.
    /// Surfaced on the closing card, so it has to be honest per backend.
    static func tag(for backend: ChatBackendID) -> InsightModelTag {
        InsightModelTag(
            providerKey: backend.rawValue,
            modelID: backend.rawValue,
            displayName: backend.displayName,
            egressTier: backend == .hermes ? .localOnly : .userKey
        )
    }
}
