import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// The contract the editorial model is held to.
///
/// Modelled on `InsightVoiceSchemaV2`, which already establishes the rule this
/// depends on: the model authors *narrative slots only*. Here it is stricter
/// still — the model may pick, order and phrase, but every figure it is allowed
/// to write is one already computed and handed to it.
public enum RecapVoiceSchema {

    // MARK: - Limits

    public static let headlineMaxLength = 52
    public static let bodyMaxLength = 140
    public static let titleMaxLength = 58
    public static let closingMaxLength = 320

    /// Reuses the verdict surface's banned list so the two AI surfaces in the
    /// app cannot drift into different voices, plus recap-specific offenders:
    /// the breathless Wrapped register the brief explicitly rules out.
    public static let bannedPhrases: [String] = InsightVoiceSchemaV2.bannedPhrases + [
        "you crushed it",
        "you're on fire",
        "wow",
        "amazing",
        "incredible",
        "journey",
        "level up",
        "superstar",
        "rockstar",
        "let's go",
        "buckle up",
        "dive in",
        "game changer",
        "next level"
    ]

    // MARK: - Schema

    public static let jsonSchema: String = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://burnbar.ai/recap/voice-v1.schema.json",
      "title": "MonthlyRecap.voice",
      "type": "object",
      "required": ["monthTitle", "monthInOneSentence", "cards"],
      "additionalProperties": false,
      "properties": {
        "monthTitle": {
          "type": "string",
          "minLength": 8,
          "maxLength": 58,
          "description": "Names the month's character, e.g. 'August was your builder month'. Declarative. No greeting."
        },
        "monthSubtitle": {
          "type": ["string", "null"],
          "maxLength": 120,
          "description": "Optional one-line amplification of the title."
        },
        "monthInOneSentence": {
          "type": "string",
          "minLength": 40,
          "maxLength": 320,
          "description": "The closing card. Two or three sentences describing how the person worked this month, drawn only from the supplied candidates."
        },
        "cards": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "object",
            "required": ["id", "headline", "body"],
            "additionalProperties": false,
            "properties": {
              "id": {
                "type": "string",
                "description": "Must be one of the supplied candidate ids. Ids not supplied are discarded."
              },
              "headline": {
                "type": "string",
                "minLength": 4,
                "maxLength": 52,
                "description": "Short, human, declarative. May be a sentence fragment."
              },
              "body": {
                "type": "string",
                "minLength": 10,
                "maxLength": 140,
                "description": "One or two sentences. Every number must come from that candidate's metrics."
              },
              "drop": {
                "type": "boolean",
                "description": "True to leave this candidate out of the recap entirely."
              },
              "promote": {
                "type": "boolean",
                "description": "True if this insight deserves an oversized, full-width treatment."
              }
            }
          }
        }
      }
    }
    """#

    // MARK: - Prompt

    public static let systemPrompt = """
    You are the editor of a small personal magazine about how one person used AI \
    coding agents last month. You write the words. You never compute or invent numbers.

    Voice: warm, specific, quietly observant. Occasionally witty. Never breathless, \
    never congratulatory for its own sake, never corporate. Write the way a thoughtful \
    friend who happened to read the data would say it out loud.

    You respond only with a single valid JSON object. No prose outside it, no code fences.
    """

    public static func userPrompt(payloadJSON: String) -> String {
        """
        Below are candidate insights about this person's month. Each one is already \
        true and already carries its own numbers. Your job is editorial, not analytical.

        For each candidate you keep, write a `headline` (max \(headlineMaxLength) chars) \
        and a `body` (max \(bodyMaxLength) chars) that say what the deterministic copy \
        says, but better — more human, more specific, less like a report.

        Then write `monthTitle`, naming what kind of month this was \
        (e.g. "August was your builder month"), and `monthInOneSentence`, a short \
        closing paragraph describing how they worked.

        Hard rules:
        - Every number you write must appear in that candidate's `metrics` or \
        `comparison`. Do not compute new figures, do not round differently, do not \
        combine two numbers into a third.
        - Use only the candidate ids given. Set `drop: true` for anything not worth \
        a card. Order your `cards` array the way the recap should read.
        - Placeholders like {project1} refer to private names. Keep them verbatim \
        wherever you mention that project; never guess what they stand for.
        - Do not greet, do not summarise the rules back, do not use these phrases: \
        \(bannedPhrases.prefix(12).joined(separator: ", ")).

        CANDIDATES:
        \(payloadJSON)

        Respond with only a JSON object matching this schema:
        \(jsonSchema)
        """
    }
}

// MARK: - Response

/// What the model is expected to return, before validation.
public struct RecapVoiceResponse: Codable, Sendable {

    public struct Card: Codable, Sendable {
        public let id: String
        public let headline: String
        public let body: String
        public let drop: Bool?
        public let promote: Bool?
    }

    public let monthTitle: String
    public let monthSubtitle: String?
    public let monthInOneSentence: String
    public let cards: [Card]
}
