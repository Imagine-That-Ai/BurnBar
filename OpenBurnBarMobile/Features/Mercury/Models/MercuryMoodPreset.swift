import SwiftUI

/// A one-tap "vibe" the user can apply to a Mac. Sets accent, background,
/// avatar style, and haptics together so users don't have to fiddle with
/// eight sliders to land somewhere good. The carousel of presets is the
/// centerpiece of the personalization surface.
struct MercuryMoodPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let tagline: String
    let accent: MercuryAccent
    let background: MercuryBackgroundStyle
    let avatar: MercuryAvatarStyle
    let haptics: MercuryHapticsLevel
    /// Two colors used to render the mini preview swatch on the carousel
    /// card. Independent from `accent` so presets like "Aurora" can show
    /// a multi-color preview while still tinting via auto-from-wallpaper.
    let previewColors: [Color]

    static let allPresets: [MercuryMoodPreset] = [
        MercuryMoodPreset(
            id: "aurora",
            name: "Aurora",
            tagline: "From your wallpaper",
            accent: .autoFromWallpaper,
            background: .wallpaper,
            avatar: .laptop,
            haptics: .gentle,
            previewColors: [
                Color(red: 0.40, green: 0.55, blue: 0.85),
                Color(red: 0.65, green: 0.45, blue: 0.95)
            ]
        ),
        MercuryMoodPreset(
            id: "ember",
            name: "Ember",
            tagline: "Warm + grounded",
            accent: .ember,
            background: .aurora,
            avatar: .laptop,
            haptics: .crisp,
            previewColors: [
                MercuryAccent.ember.staticColor,
                MercuryAccent.amber.staticColor
            ]
        ),
        MercuryMoodPreset(
            id: "whimsy",
            name: "Whimsy",
            tagline: "Playful + bright",
            accent: .whimsy,
            background: .aurora,
            avatar: .symbol("sparkles"),
            haptics: .crisp,
            previewColors: [
                MercuryAccent.whimsy.staticColor,
                MercuryAccent.pink.staticColor
            ]
        ),
        MercuryMoodPreset(
            id: "stealth",
            name: "Stealth",
            tagline: "Cool + quiet",
            accent: .blue,
            background: .solid,
            avatar: .laptop,
            haptics: .gentle,
            previewColors: [
                Color(red: 0.20, green: 0.35, blue: 0.60),
                Color(red: 0.10, green: 0.18, blue: 0.30)
            ]
        ),
        MercuryMoodPreset(
            id: "mercury",
            name: "Mercury",
            tagline: "Silver + serene",
            accent: .teal,
            background: .aurora,
            avatar: .symbol("macbook"),
            haptics: .gentle,
            previewColors: [
                Color(red: 0.78, green: 0.74, blue: 0.69),
                Color(red: 0.63, green: 0.67, blue: 0.73)
            ]
        ),
        MercuryMoodPreset(
            id: "sunset",
            name: "Sunset",
            tagline: "Pink + golden hour",
            accent: .pink,
            background: .wallpaper,
            avatar: .laptop,
            haptics: .crisp,
            previewColors: [
                MercuryAccent.pink.staticColor,
                MercuryAccent.amber.staticColor
            ]
        )
    ]

    /// Returns the preset whose accent + background + haptics best match
    /// the user's current personalization (avatar is ignored to allow
    /// avatar-only overrides without losing the mood). `nil` when no
    /// preset matches — the user has gone custom.
    static func matching(_ personalization: MercuryDevicePersonalization) -> MercuryMoodPreset? {
        allPresets.first {
            $0.accent == personalization.accent
                && $0.background == personalization.background
                && $0.haptics == personalization.haptics
        }
    }

    func apply(to personalization: inout MercuryDevicePersonalization) {
        personalization.accent = accent
        personalization.background = background
        personalization.haptics = haptics
        // Only overwrite avatar when the user is still on the default
        // (.laptop) so we don't blow away an emoji/photo they chose.
        if personalization.avatar.kind == .laptop {
            personalization.avatar = avatar
        }
    }
}
