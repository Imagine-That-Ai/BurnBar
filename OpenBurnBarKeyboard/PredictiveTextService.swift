import Foundation
import UIKit

// MARK: - Predictive Text Service
/// Provides next-word predictions based on the previous word using a
/// combination of common English bigrams and UITextChecker completions.
///
/// Returns up to 2 predicted next words to display in the suggestion bar.
@MainActor
final class PredictiveTextService {

    /// Common English bigrams — maps a lowercase word to its most likely successors.
    /// Covers the ~150 most frequent word transitions in English.
    private let bigrams: [String: [String]] = [
        // Pronouns
        "i":      ["am", "have", "will", "was", "think", "can", "need", "want", "like", "don't"],
        "you":    ["are", "can", "have", "want", "need", "should", "could", "will", "know", "think"],
        "he":     ["is", "was", "has", "will", "said", "had", "would", "can", "could", "did"],
        "she":    ["is", "was", "has", "will", "said", "had", "would", "can", "could", "did"],
        "we":     ["are", "have", "can", "will", "should", "need", "could", "would", "were", "don't"],
        "they":   ["are", "have", "can", "will", "were", "would", "should", "could", "don't", "said"],
        "it":     ["is", "was", "will", "would", "can", "has", "could", "should", "doesn't", "seems"],
        "my":     ["name", "phone", "email", "address", "friend", "family", "work", "life", "best", "favorite"],
        "your":   ["name", "email", "phone", "address", "message", "account", "order", "password", "welcome", "turn"],
        "this":   ["is", "was", "will", "would", "should", "can", "could", "has", "one", "morning"],
        "that":   ["is", "was", "would", "will", "the", "could", "should", "can", "has", "it"],
        "what":   ["is", "are", "do", "did", "does", "was", "would", "should", "time", "about"],

        // Common verbs
        "is":     ["a", "the", "not", "it", "this", "that", "there", "going", "very", "really"],
        "are":    ["you", "the", "not", "we", "they", "there", "going", "doing", "coming", "looking"],
        "was":    ["a", "the", "not", "it", "just", "going", "very", "really", "so", "there"],
        "have":   ["a", "to", "been", "the", "you", "not", "any", "some", "no", "it"],
        "has":    ["been", "a", "the", "to", "not", "no", "any", "some", "already", "just"],
        "had":    ["a", "to", "been", "the", "no", "not", "some", "already", "just", "never"],
        "do":     ["you", "not", "it", "this", "that", "we", "they", "the", "anything", "something"],
        "don't":  ["know", "have", "want", "think", "need", "worry", "forget", "like", "be", "do"],
        "can":    ["you", "I", "we", "be", "do", "get", "help", "see", "make", "take"],
        "will":   ["be", "you", "have", "do", "get", "not", "need", "make", "take", "come"],
        "would":  ["be", "you", "like", "have", "love", "not", "rather", "say", "do", "think"],
        "could":  ["you", "be", "have", "not", "I", "we", "do", "use", "get", "make"],
        "should":  ["be", "I", "have", "we", "you", "not", "do", "get", "know", "take"],
        "going":  ["to", "on", "out", "home", "back", "well", "forward", "through", "down", "up"],
        "want":   ["to", "a", "the", "it", "you", "me", "some", "this", "that", "more"],
        "need":   ["to", "a", "the", "it", "you", "some", "help", "more", "this", "your"],
        "like":   ["to", "a", "the", "it", "this", "that", "you", "me", "how", "what"],
        "know":   ["that", "what", "how", "if", "you", "the", "about", "it", "when", "where"],
        "think":  ["that", "about", "it", "so", "you", "the", "I", "we", "of", "this"],
        "get":    ["a", "the", "it", "to", "back", "out", "up", "some", "home", "your"],
        "got":    ["a", "the", "it", "to", "some", "my", "your", "back", "home", "up"],
        "make":   ["a", "it", "the", "sure", "up", "me", "you", "some", "this", "your"],
        "go":     ["to", "out", "home", "back", "ahead", "on", "for", "with", "now", "there"],
        "come":   ["on", "back", "in", "to", "out", "here", "home", "over", "up", "with"],
        "see":    ["you", "the", "if", "what", "it", "how", "a", "that", "my", "this"],
        "take":   ["a", "the", "it", "care", "off", "out", "up", "me", "your", "some"],
        "let":    ["me", "us", "it", "him", "her", "them", "the", "you", "go", "know"],

        // Articles/prepositions
        "the":    ["best", "most", "first", "same", "other", "new", "next", "last", "right", "way"],
        "a":      ["lot", "new", "good", "great", "few", "little", "big", "long", "very", "bit"],
        "an":     ["email", "hour", "issue", "error", "update", "example", "option", "important", "account", "app"],
        "to":     ["be", "do", "get", "have", "make", "go", "see", "know", "take", "the"],
        "in":     ["the", "a", "my", "your", "this", "that", "order", "case", "fact", "general"],
        "on":     ["the", "my", "your", "a", "it", "this", "that", "time", "top", "Monday"],
        "for":    ["the", "a", "you", "your", "me", "this", "that", "it", "my", "some"],
        "with":   ["the", "a", "you", "your", "me", "my", "this", "that", "it", "some"],
        "at":     ["the", "a", "all", "least", "home", "work", "this", "that", "it", "my"],
        "of":     ["the", "a", "my", "your", "it", "this", "that", "course", "them", "us"],
        "from":   ["the", "a", "my", "your", "here", "there", "home", "work", "now", "this"],

        // Common phrases
        "thank":  ["you", "goodness"],
        "thanks": ["for", "so", "a"],
        "how":    ["are", "is", "do", "did", "does", "was", "about", "much", "many", "long"],
        "yes":    ["I", "please", "sure", "of", "that", "it", "we", "they", "absolutely", "definitely"],
        "no":     ["I", "problem", "worries", "thanks", "thank", "one", "way", "idea", "it", "not"],
        "not":    ["sure", "a", "the", "yet", "only", "just", "be", "have", "going", "really"],
        "just":   ["a", "the", "wanted", "got", "had", "let", "need", "want", "saw", "heard"],
        "so":     ["I", "much", "many", "far", "that", "you", "we", "it", "the", "sorry"],
        "really": ["good", "great", "nice", "like", "want", "need", "appreciate", "sorry", "hope", "think"],
        "very":   ["much", "good", "nice", "well", "happy", "sorry", "important", "interesting", "helpful", "cool"],
        "please": ["let", "send", "call", "help", "check", "confirm", "note", "see", "find", "contact"],

        // Tech / messaging
        "ok":     ["thanks", "great", "sure", "I", "sounds", "cool", "no", "let", "perfect", "will"],
        "okay":   ["thanks", "great", "sure", "I", "sounds", "cool", "no", "let", "perfect", "will"],
        "hey":    ["there", "how", "what", "I", "can", "are", "do", "sorry", "thanks", "just"],
        "hi":     ["there", "how", "I", "thanks", "everyone", "all", "sorry", "hope", "just", "can"],
        "hello":  ["there", "how", "I", "everyone", "world", "and", "again", "from", "to", "all"],
        "sure":   ["thing", "I", "no", "thanks", "let", "that", "sounds", "will", "of", "why"],
        "sounds": ["good", "great", "like", "fun", "interesting", "perfect", "right", "awesome", "cool", "nice"],
        "good":   ["morning", "afternoon", "evening", "night", "luck", "job", "idea", "point", "question", "news"],
        "great":  ["thanks", "job", "idea", "work", "news", "question", "point", "to", "looking", "meeting"],
        "sorry":  ["for", "about", "I", "to", "but", "if", "that", "the"],
        "lol":    ["that", "yeah", "I", "thanks", "true", "right", "nice", "ok"],
    ]

    /// Fallback predictions when no bigram match exists.
    private let commonStarters = ["I", "the", "it", "you", "we", "that", "this", "my", "so", "and"]

    /// Returns up to 2 predicted next words based on the previous word.
    func predict(afterWord word: String?) -> [String] {
        guard let word = word?.lowercased(), !word.isEmpty else {
            return Array(commonStarters.prefix(2))
        }

        if let candidates = bigrams[word] {
            return Array(candidates.prefix(2))
        }

        // No bigram match — return common starters
        return Array(commonStarters.prefix(2))
    }

    /// Returns up to 2 predictions given the full text context.
    /// Extracts the last completed word (before cursor) and predicts.
    func predict(fromContext context: String?) -> [String] {
        guard let context = context, !context.isEmpty else {
            return Array(commonStarters.prefix(2))
        }

        // Only predict after a space (word boundary)
        guard context.last == " " || context.last == "\n" else {
            return []  // User is mid-word — spell check handles this
        }

        // Get the last word before the trailing space
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.components(separatedBy: .whitespacesAndNewlines)
        guard let lastWord = components.last, !lastWord.isEmpty else {
            return Array(commonStarters.prefix(2))
        }

        return predict(afterWord: lastWord)
    }
}
