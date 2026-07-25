import Foundation
import Combine
import Darwin
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import OSLog
import AppKit
import ImageIO

/// F7 — thrown when `MediaFrameAeadNegotiation` refuses a lane because sealing
/// was expected but could not be established. Surfaced to the viewer as an
/// `.unsupported` mirror ack (via `failAcceptedMirrorRuntime`) so a de-negotiated
/// peer sees a clean "media unavailable" banner instead of the lane silently
/// degrading to plaintext-over-QUIC.
enum MercuryLaneSealingError: LocalizedError {
    case refused(reason: MediaFrameAeadNegotiation.SealingDecision.RefusalReason)

    var errorDescription: String? {
        switch self {
        case .refused(let reason):
            switch reason {
            case .remoteDoesNotSupportSealing:
                return "This media lane requires per-frame encryption that the other device does not support."
            case .localDoesNotSupportSealing:
                return "This media lane requires per-frame encryption that this Mac cannot provide."
            case .sessionKeyUnavailable:
                return "This media lane requires per-frame encryption, but a media-seal session key could not be established."
            }
        }
    }
}

enum MercuryRemoteAccessAgentClientError: Error {
    case socketUnavailable
    case socketPathTooLong
    case daemonUnavailable
    case timedOut
    case writeFailed
    case readFailed
    case responseTooLarge
    case daemonRejected
}

extension String {
    var nilIfEmptyForMercury: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var canonicalMercuryPeerNodeID: String? {
        nilIfEmptyForMercury?.lowercased()
    }
}
