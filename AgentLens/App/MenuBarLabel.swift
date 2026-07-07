import AppKit
import OpenBurnBarCore
import SwiftUI

// Extracted verbatim from AgentLensApp.swift (audit wave 4, item 14).
// The SwiftUI menu-bar label (brand mark + refresh/cost-increase/daily
// pulse overlays) and its rasterized brand-mark image.

/// Rasterizes `AppLogo` so `MenuBarExtra` gets a normal menu-bar icon size.
private enum MenuBarRasterBrandMark {
    static let side: CGFloat = 18

    static let image: NSImage = {
        let empty = NSImage(size: NSSize(width: side, height: side))
        guard let source = NSImage(named: "AppLogo") else { return empty }
        let target = NSSize(width: side, height: side)
        return NSImage(size: target, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .high
            let from = NSRect(origin: .zero, size: source.size)
            source.draw(in: rect, from: from, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }()
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let totalCostToday: Double
    let totalTokensToday: Int
    let usageDisplayMode: UsageDisplayMode
    let rollingDailyAverage: Double
    let isRefreshing: Bool

    @State private var showCostIncrease = false
    @State private var bounceTick = 0
    @State private var logoBounceScale: CGFloat = 1
    @State private var pulseGlow: CGFloat = 0
    @AppStorage("lastDailyCostPulseDay") private var lastDailyCostPulseDay: String = ""

    /// Shown on hover in the menu bar (balance for the selected display mode).
    private var balanceTooltip: String {
        switch usageDisplayMode {
        case .currency:
            return "Today: \(totalCostToday.formatAsCost())"
        case .tokens:
            return "Today: \(totalTokensToday.formatAsTokenVolume()) tokens"
        }
    }

    private var todayDayKey: String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var shouldDailyPulse: Bool {
        rollingDailyAverage > 0 && totalCostToday > rollingDailyAverage * 1.2
    }

    static let menuBarLabelSlotWidth: CGFloat = 22
    static let menuBarLabelSlotHeight: CGFloat = 18

    private var menuBarIcon: some View {
        Image(nsImage: MenuBarRasterBrandMark.image)
    }

    var body: some View {
        Label {
            EmptyView()
        } icon: {
            menuBarIcon
                .scaleEffect(logoBounceScale)
                .shadow(color: Color.primary.opacity(pulseGlow * 0.35), radius: pulseGlow * 3)
        }
        .labelStyle(.iconOnly)
        .overlay(alignment: .topTrailing) {
            Group {
                if isRefreshing {
                    AnimatedMiningPickView()
                        .frame(width: 14, height: 14)
                        .clipShape(.circle)
                        .scaleEffect(0.5)
                        .offset(x: 3, y: -3)
                } else if showCostIncrease {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.green)
                        .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                        .offset(x: 3, y: -2)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: Self.menuBarLabelSlotWidth, height: Self.menuBarLabelSlotHeight)
        .fixedSize()
        .help(balanceTooltip)
        .accessibilityLabel("\(OpenBurnBarIdentity.productName), \(balanceTooltip)")
        .onChange(of: isRefreshing) { _, new in
            guard !new else { return }
            Task { @MainActor in
                bounceTick &+= 1
            }
        }
        .onChange(of: bounceTick) { _, _ in
            Task { @MainActor in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                    logoBounceScale = 1.14
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                        logoBounceScale = 1
                    }
                }
            }
        }
        .onChange(of: totalCostToday) { oldValue, newValue in
            guard newValue > oldValue, oldValue > 0 else { return }
            Task { @MainActor in
                withAnimation(.easeIn(duration: 0.2)) {
                    showCostIncrease = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showCostIncrease = false
                    }
                }
            }
        }
        .onChange(of: shouldDailyPulse) { _, pulse in
            guard pulse, lastDailyCostPulseDay != todayDayKey else { return }
            Task { @MainActor in
                lastDailyCostPulseDay = todayDayKey
                pulseGlow = 0
                withAnimation(.easeInOut(duration: 0.45)) {
                    pulseGlow = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.6)) {
                        pulseGlow = 0
                    }
                }
            }
        }
    }
}
