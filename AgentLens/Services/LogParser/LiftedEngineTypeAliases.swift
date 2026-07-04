import Foundation
import OpenBurnBarCore

// MARK: - Lifted shared-model aliases (Mac side ↔ OpenBurnBarCore canonical)
//
// Windows-port Phase-2 (G2 parser lift). The 4 golden-covered log parsers and
// their shared infra are compiled into the macOS app target from the same
// OpenBurnBarCore source files so package-internal parser APIs stay internal.
// The conversation models are public package API, so keep the old unqualified
// app call sites compiling with a small local alias.

typealias ConversationRecord = OpenBurnBarCore.ConversationRecord
typealias ConversationSourceType = OpenBurnBarCore.ConversationSourceType
typealias Locked<T: Sendable> = OpenBurnBarCore.Locked<T>
