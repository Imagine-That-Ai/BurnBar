import Foundation

// MARK: - Pet reaction brain

/// BurnBar's Swift mirror of the shared `petcore` reaction contract.
///
/// Keep this file vocabulary-only: it consumes senses and available semantic clip
/// names, then returns one clip/state name. When `pickReaction` lands in a
/// generated/shared Swift surface from `petcore`, this is the single swap point.
enum PetMessageIntent: String, Codable, Hashable, Sendable {
    case neutral
    case question
    case praise
    case hostile
    case dismiss
    case negate
    case confused
}

enum PetTaskOutcome: String, Codable, Hashable, Sendable {
    case normalReply
    case success
    case bigWin
    case failure
    case hardError
}

struct PetReactionSenses: Sendable {
    var availableClips: Set<String>
    var sinceInteraction: TimeInterval
    var userTyping: Bool
    var agentBusy: Bool
    var appFocused: Bool
    var osIdle: Bool
    var pointerNear: Bool
    var lastIntent: PetMessageIntent?
    var lastIntentAge: TimeInterval?
    var repeatedIntentCount: Int
    var lastOutcome: PetTaskOutcome?
    var lastOutcomeAge: TimeInterval?
    var timeOfDayHour: Int
    var wasSleeping: Bool
    var ambientPulse: Bool
}

enum PetReactionBrain {
    static func pickReaction(_ senses: PetReactionSenses) -> String? {
        let clips = senses.availableClips
        guard !clips.isEmpty else { return nil }

        if senses.wasSleeping, isFresh(senses.lastIntentAge, within: 3) {
            return choose(["excited", "wave", "standUp", "idle"], from: clips)
        }

        if let intent = senses.lastIntent, isFresh(senses.lastIntentAge, within: 8) {
            switch intent {
            case .question:
                return choose(["think", "confused", "idle"], from: clips)
            case .praise:
                return choose(["cheer", "bow", "wave", "idle"], from: clips)
            case .hostile:
                let escalated = senses.repeatedIntentCount > 1
                return choose(
                    escalated
                        ? ["stomp", "flinch", "offended", "sad", "idle"]
                        : ["offended", "flinch", "stomp", "idle"],
                    from: clips
                )
            case .dismiss:
                return choose(["retreat", "sleep", "doze", "idle"], from: clips)
            case .negate:
                return choose(["no", "shrug", "idle"], from: clips)
            case .confused:
                return choose(["confused", "shrug", "idle"], from: clips)
            case .neutral:
                break
            }
        }

        if senses.agentBusy {
            return choose(["think", "confused", "idle"], from: clips)
        }

        if senses.userTyping {
            return choose(["listen", "idle"], from: clips)
        }

        if let outcome = senses.lastOutcome, isFresh(senses.lastOutcomeAge, within: 8) {
            switch outcome {
            case .normalReply:
                return choose(["nod", "wave", "idle"], from: clips)
            case .success:
                return choose(["cheer", "victory", "celebrate", "clap", "idle"], from: clips)
            case .bigWin:
                return choose(["victory", "dance", "celebrate", "taunt", "cheer", "idle"], from: clips)
            case .failure:
                return choose(["sad", "confused", "shrug", "idle"], from: clips)
            case .hardError:
                return choose(["zap", "flinch", "sad", "confused", "idle"], from: clips)
            }
        }

        let night = senses.timeOfDayHour >= 23 || senses.timeOfDayHour < 6
        let dozeAt: TimeInterval = night ? 45 : 60
        let sleepAt: TimeInterval = night ? 120 : 180
        let retreatAt: TimeInterval = night ? 240 : 300

        if senses.osIdle || !senses.appFocused {
            if senses.sinceInteraction >= dozeAt {
                return choose(["sleep", "doze", "sitDown", "idle"], from: clips)
            }
            return choose(["doze", "sleep", "idle"], from: clips)
        }

        if senses.pointerNear, senses.sinceInteraction > 8 {
            return choose(["lookAround", "listen", "wave", "idle"], from: clips)
        }

        if senses.sinceInteraction >= retreatAt {
            return choose(["retreat", "wander", "sleep", "idle"], from: clips)
        }
        if senses.sinceInteraction >= sleepAt {
            return choose(["sleep", "doze", "idle"], from: clips)
        }
        if senses.sinceInteraction >= dozeAt {
            return choose(["doze", "stretch", "idle"], from: clips)
        }

        if senses.ambientPulse, senses.sinceInteraction >= 20 {
            let morning = (6...10).contains(senses.timeOfDayHour)
            return choose(
                morning
                    ? ["excited", "stretch", "idleVar", "lookAround", "idle"]
                    : ["idleVar", "stretch", "lookAround", "sip", "vanity", "idle"],
                from: clips
            )
        }

        return nil
    }

    static func classifyMessage(_ text: String) -> PetMessageIntent {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return .neutral }

        if containsAny(normalized, [
            "fuck off", "f*** off", "shut up", "stupid", "idiot", "useless",
            "dumb", "hate you", "you suck", "trash"
        ]) {
            return .hostile
        }

        if containsAny(normalized, [
            "go away", "leave", "dismiss", "bye", "goodbye", "go sleep",
            "leave me alone"
        ]) {
            return .dismiss
        }

        if containsAny(normalized, [
            "thanks", "thank you", "nice", "good job", "great job", "well done",
            "love it", "perfect", "beautiful"
        ]) {
            return .praise
        }

        let words = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if words.contains("wrong") || words.contains("stop") || words.contains("no")
            || normalized.contains("don't") || normalized.contains("dont") {
            return .negate
        }

        if normalized.hasSuffix("?")
            || startsWithAny(normalized, ["who ", "what ", "why ", "how ", "when ", "where "])
            || containsAny(normalized, ["can you", "could you", "would you", "do you"]) {
            return .question
        }

        return .neutral
    }

    private static func isFresh(_ age: TimeInterval?, within limit: TimeInterval) -> Bool {
        guard let age else { return false }
        return age >= 0 && age <= limit
    }

    private static func choose(_ candidates: [String], from clips: Set<String>) -> String? {
        for candidate in candidates where clips.contains(candidate) {
            return candidate
        }
        if clips.contains("idle") { return "idle" }
        return clips.min()
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func startsWithAny(_ text: String, _ prefixes: [String]) -> Bool {
        prefixes.contains { text.hasPrefix($0) }
    }
}
