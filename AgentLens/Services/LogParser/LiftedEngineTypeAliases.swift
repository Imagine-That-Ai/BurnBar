import Foundation
import OpenBurnBarCore

// MARK: - Lifted parser/infra aliases (Mac side ↔ OpenBurnBarCore canonical)
//
// Windows-port Phase-2 (G2 parser lift). The 4 golden-covered log parsers and
// their shared infra were lifted from the macOS app into `OpenBurnBarCore` so the
// SAME parser code is Windows-buildable and byte-diffed by the G2 CI gate. To keep
// the existing macOS call sites compiling without sprinkling `import OpenBurnBarCore`
// across ~27 files, the lifted types are re-exported here as module-internal
// typealiases — exactly the pattern already used for `AgentProvider` / `TokenUsage`
// in `AgentLens/Models/AgentProvider.swift`. Files that use the lifted FileHandle
// EXTENSION methods (`readAllUTF8Lines`, `readLine`) still import the module
// directly, since extension members are not re-exported by a typealias.

typealias OpenBurnBarIdentity = OpenBurnBarCore.OpenBurnBarIdentity
typealias OpenBurnBarAppPaths = OpenBurnBarCore.OpenBurnBarAppPaths
typealias OpenBurnBarMigration = OpenBurnBarCore.OpenBurnBarMigration
typealias OpenBurnBarDefaultsMigration = OpenBurnBarCore.OpenBurnBarDefaultsMigration
typealias OpenBurnBarFilesystemMigration = OpenBurnBarCore.OpenBurnBarFilesystemMigration

typealias ConversationRecord = OpenBurnBarCore.ConversationRecord
typealias ConversationSourceType = OpenBurnBarCore.ConversationSourceType

typealias ParseResult = OpenBurnBarCore.ParseResult
typealias LogParseOptions = OpenBurnBarCore.LogParseOptions
typealias LogParser = OpenBurnBarCore.LogParser

typealias ClaudeCodeParser = OpenBurnBarCore.ClaudeCodeParser
typealias FactoryDroidParser = OpenBurnBarCore.FactoryDroidParser
typealias ParserConversationCacheScrubber = OpenBurnBarCore.ParserConversationCacheScrubber
typealias ForgeDevParser = OpenBurnBarCore.ForgeDevParser
typealias GooseParser = OpenBurnBarCore.GooseParser
typealias WindsurfParser = OpenBurnBarCore.WindsurfParser
typealias WarpParser = OpenBurnBarCore.WarpParser
typealias HermesParser = OpenBurnBarCore.HermesParser

typealias ModelPricing = OpenBurnBarCore.ModelPricing
typealias TokenExtractionUtility = OpenBurnBarCore.TokenExtractionUtility
typealias ExtractedTokenUsage = OpenBurnBarCore.ExtractedTokenUsage
typealias EstimatedTokens = OpenBurnBarCore.EstimatedTokens
typealias TimestampNormalizationUtility = OpenBurnBarCore.TimestampNormalizationUtility

typealias ClaudeConversationAccumulator = OpenBurnBarCore.ClaudeConversationAccumulator
typealias BufferedLineSequence = OpenBurnBarCore.BufferedLineSequence
typealias SessionLogMarkdownFormatter = OpenBurnBarCore.SessionLogMarkdownFormatter

typealias FileSignature = OpenBurnBarCore.FileSignature
typealias CompositeFileSignature = OpenBurnBarCore.CompositeFileSignature
typealias ParserDiskCache = OpenBurnBarCore.ParserDiskCache
typealias ParserDiskCacheStore = OpenBurnBarCore.ParserDiskCacheStore
