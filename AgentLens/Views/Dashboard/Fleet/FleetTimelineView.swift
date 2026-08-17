import SwiftUI

// MARK: - Fleet copy
//
// One place that decides what each liveness state is *called*.
//
// Centralized for the same reason `InboxPresentation` is: a new state should
// get coherent wording by adding one case here, not by three views inventing
// three different phrasings for the same fact.

enum FleetCopy {

    /// The phrase shown beside a row's dot.
    ///
    /// Note what is absent: no state renders as "idle", and none renders as
    /// "waiting on you". Neither is something this app can honestly observe.
    static func phrase(for liveness: FleetLiveness, now: Date = Date()) -> String {
        switch liveness {
        case .workingHere(let presence, let location):
            let base: String
            switch presence {
            case .streaming: base = "Answering"
            case .thinking(let since): base = "Thinking \(clock(since: since, now: now))"
            default: base = "Working"
            }
            guard let location, location.isEmpty == false else { return base }
            return "\(base) · in \(location)"

        case .wroteRecently(let at, _):
            return "wrote \(elapsed(since: at, now: now)) ago"

        case .quietSince(let since, _):
            return "quiet \(elapsed(since: since, now: now))"

        case .standingBy:
            return "Standing by"

        case .blocked(let presence):
            switch presence {
            case .needsAuth:    return "Needs sign-in"
            case .exhausted:    return "Out of quota"
            case .notInstalled: return "Not installed"
            case .offline:      return "Gateway unreachable"
            case .error(let message): return message
            default:            return "Blocked"
            }

        // Deliberately not "Idle" and not blank. A blank reads as "nothing
        // happening"; "Not watched" says the true thing, which is that we have
        // no evidence either way.
        case .unobservable:
            return "Not watched"
        }
    }

    /// The panel footer — the evidence floor for everything above it.
    static func footer(
        hasRealTimeCoverage: Bool,
        sleepGapReason: String?,
        lastScanAt: Date?,
        now: Date = Date()
    ) -> String {
        if let sleepGapReason { return sleepGapReason }
        if hasRealTimeCoverage {
            return "In-app turns live · external agents watched live"
        }
        guard let lastScanAt else {
            return "In-app turns live · external agents not yet scanned"
        }
        return "In-app turns live · external agents as of last scan \(elapsed(since: lastScanAt, now: now)) ago"
    }

    /// Compact elapsed phrasing: 12s, 6m, 3h, 2d.
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// `m:ss` for a running turn, so "Thinking 0:14" ticks like a stopwatch.
    static func clock(since date: Date, now: Date = Date()) -> String {
        let total = Int(max(0, now.timeIntervalSince(date)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Timeline

/// A 60-minute lane per agent, one tick per observed write.
///
/// This is the most honest fleet presentation — it plots *evidence* rather than
/// inferred state — which is exactly why it is gated out of the picker until
/// the filesystem watchers are armed. Fed only by 60s-cadence parsed rows every
/// tick would cluster at "last scan" and imply a precision we do not have.
///
/// Unwatched intervals draw as a hatched band rather than empty space. Empty
/// space reads as "nothing happened", which is the lie this whole feature is
/// built to avoid.
struct FleetTimelineView: View {
    let rows: [FleetAgentRow]
    let ink: BackdropInk
    var window: TimeInterval = 60 * 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(rows) { row in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        ProviderLogoView(provider: row.provider, size: 14, useFallbackColor: true)
                            .opacity(row.liveness.isActive ? 1 : 0.6)
                            .frame(width: 16)

                        lane(for: row)
                            .frame(height: 14)
                            .frame(maxWidth: .infinity)
                    }
                    .help("\(row.provider.displayName) — \(FleetCopy.phrase(for: row.liveness))")
                }

                HStack {
                    Text("60m ago").font(DesignSystem.Typography.tiny).foregroundStyle(ink.subtle)
                    Spacer()
                    Text("now").font(DesignSystem.Typography.tiny).foregroundStyle(ink.subtle)
                }
                .padding(.leading, 24)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
        }
    }

    @ViewBuilder
    private func lane(for row: FleetAgentRow) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ink.hairline.opacity(0.35))

                if case .unobservable = row.liveness {
                    // Hatched: we were not watching. Distinct from an empty
                    // lane, which would claim the agent did nothing.
                    HatchBand()
                        .stroke(ink.subtle.opacity(0.5), lineWidth: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else if let mark = tickOffset(for: row, width: geo.size.width) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(row.liveness.isActive ? DesignSystem.Colors.success : ink.icon)
                        .frame(width: 3)
                        .offset(x: mark)
                }
            }
        }
    }

    /// x-offset of the most recent observed write within the window, or nil
    /// when there is nothing to plot.
    private func tickOffset(for row: FleetAgentRow, width: CGFloat) -> CGFloat? {
        let date: Date
        switch row.liveness {
        case .wroteRecently(let at, _): date = at
        case .quietSince(let since, _): date = since
        default: return nil
        }
        let age = Date().timeIntervalSince(date)
        guard age >= 0, age <= window, width > 3 else { return nil }
        let fraction = 1 - (age / window)
        return max(0, min(width - 3, CGFloat(fraction) * width))
    }
}

/// Diagonal hatching for an interval we were not watching.
private struct HatchBand: Shape {
    var spacing: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
