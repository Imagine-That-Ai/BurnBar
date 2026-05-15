import SwiftUI

// MARK: - Pro Theme (macOS)
//
// macOS variant of the OpenBurnBar Cloud "luxury island in utilitarian sea"
// vocabulary. Mirrors `OpenBurnBarMobile/Theme/ProTheme.swift` so a member
// who buys on iPhone walks into the macOS dashboard and sees the same world.
// Composes existing `DesignSystem.Colors.hermesMercury` / `hermesAureate`
// primitives — only the obsidian palette is net-new.

enum ProTheme {

    // MARK: - Palette
    enum Palette {
        static let obsidian = Color(red: 0.040, green: 0.040, blue: 0.052)
        static let obsidianElevated = Color(red: 0.070, green: 0.070, blue: 0.085)
        static let mercury = DesignSystem.Colors.hermesMercury
        static let aureate = DesignSystem.Colors.hermesAureate
        static let emberPop = DesignSystem.Colors.ember

        static let aureateStroke = LinearGradient(
            colors: [aureate.opacity(0.95), mercury.opacity(0.98), aureate.opacity(0.95)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let darkAuroraRibbon = LinearGradient(
            colors: [
                emberPop.opacity(0.32),
                DesignSystem.Colors.amber.opacity(0.18),
                mercury.opacity(0.14),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Type voice
    enum Typography {
        static let displaySerif = Font.system(size: 40, weight: .heavy, design: .serif)
        static let titleSerif = Font.system(size: 26, weight: .bold, design: .serif)
        static let headlineSerif = Font.system(size: 18, weight: .semibold, design: .serif)
        static let priceMono = Font.system(size: 20, weight: .semibold, design: .monospaced)
    }

    // MARK: - Motion
    enum Motion {
        static let specular = Animation.linear(duration: 2.8)
        static let breathing = Animation.easeInOut(duration: 2.4).repeatForever(autoreverses: true)
        static let posterSettle = Animation.spring(response: 0.55, dampingFraction: 0.78)
    }

    // MARK: - Layout
    enum Layout {
        static let cardRadius: CGFloat = 18
        static let bandRadius: CGFloat = 14
        static let foilStroke: CGFloat = 1.0
        static let crestLarge: CGFloat = 44
        static let crestMedium: CGFloat = 32
        static let crestSmall: CGFloat = 20
        static let badgeDot: CGFloat = 6
    }
}
