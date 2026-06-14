import SwiftUI

extension OpenBurnBarMissionLifecycle {
    var color: Color {
        switch self {
        case .planned: return DesignSystem.Colors.textSecondary
        case .running: return DesignSystem.Colors.blaze
        case .partial: return DesignSystem.Colors.amber
        case .blocked: return DesignSystem.Colors.error
        case .completed: return DesignSystem.Colors.success
        }
    }
}

extension OpenBurnBarMissionApprovalState {
    var color: Color {
        switch self {
        case .pending: return DesignSystem.Colors.amber
        case .approved: return DesignSystem.Colors.success
        }
    }
}

extension OpenBurnBarDirectionAssessment {
    var color: Color {
        switch self {
        case .aligned: return DesignSystem.Colors.success
        case .drifting: return DesignSystem.Colors.warning
        case .ambiguous: return DesignSystem.Colors.blaze
        case .notEnoughSignal: return DesignSystem.Colors.textSecondary
        }
    }
}

extension OpenBurnBarFreshnessKind {
    var color: Color {
        switch self {
        case .live: return DesignSystem.Colors.success
        case .provisional: return DesignSystem.Colors.amber
        case .stale: return DesignSystem.Colors.warning
        case .missing: return DesignSystem.Colors.textSecondary
        }
    }
}

extension OpenBurnBarEvidenceFreshness {
    var color: Color {
        switch self {
        case .fresh: return DesignSystem.Colors.success
        case .stale: return DesignSystem.Colors.warning
        case .unknown: return DesignSystem.Colors.textSecondary
        }
    }
}

extension OpenBurnBarActionTone {
    var color: Color {
        switch self {
        case .success: return DesignSystem.Colors.success
        case .error: return DesignSystem.Colors.error
        case .neutral: return DesignSystem.Colors.textSecondary
        }
    }
}

extension OpenBurnBarOperatingHistoryEntry {
    var tint: Color {
        switch kind {
        case .missionApproval: return DesignSystem.Colors.success
        case .missionCreation: return DesignSystem.Colors.hermesAureate
        case .directionOverride: return DesignSystem.Colors.whimsy
        }
    }
}

extension OpenBurnBarControllerQuestionPriority {
    var color: Color {
        switch self {
        case .high: return DesignSystem.Colors.error
        case .medium: return DesignSystem.Colors.amber
        case .low: return DesignSystem.Colors.textSecondary
        }
    }
}

extension OpenBurnBarControllerTakeoverState {
    var color: Color {
        switch self {
        case .monitoring: return DesignSystem.Colors.textSecondary
        case .launched: return DesignSystem.Colors.blaze
        case .completed: return DesignSystem.Colors.success
        case .failed: return DesignSystem.Colors.error
        case .skipped: return DesignSystem.Colors.textMuted
        }
    }
}

extension OpenBurnBarControllerEventCategory {
    var color: Color {
        switch self {
        case .controller: return DesignSystem.Colors.blaze
        case .question: return DesignSystem.Colors.amber
        case .followup: return DesignSystem.Colors.whimsy
        case .mission: return DesignSystem.Colors.hermesAureate
        case .notification: return DesignSystem.Colors.teal
        case .replay: return DesignSystem.Colors.textSecondary
        case .governance: return DesignSystem.Colors.success
        }
    }
}

extension OpenBurnBarControllerFeedback.Tone {
    var color: Color {
        switch self {
        case .success: return DesignSystem.Colors.success
        case .error: return DesignSystem.Colors.error
        }
    }
}
