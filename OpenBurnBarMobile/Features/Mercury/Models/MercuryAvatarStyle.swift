import Foundation

/// How the avatar circle on `MercuryHeaderCard` should render.
/// `.symbol` uses an SF Symbol name from the curated grid; `.emoji` is a
/// single Unicode glyph; `.photo` is a JPEG/PNG payload chosen via
/// `PhotosPicker` and compressed to fit comfortably inside the
/// `MercuryDevicePersonalization` blob (max ~80KB recommended).
enum MercuryAvatarStyle: Codable, Hashable, Sendable {
    case laptop
    case symbol(String)
    case emoji(String)
    case photo(Data)

    var kind: Kind {
        switch self {
        case .laptop:  return .laptop
        case .symbol:  return .symbol
        case .emoji:   return .emoji
        case .photo:   return .photo
        }
    }

    enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case laptop
        case symbol
        case emoji
        case photo

        var displayName: String {
            switch self {
            case .laptop: return "Laptop"
            case .symbol: return "Symbol"
            case .emoji:  return "Emoji"
            case .photo:  return "Photo"
            }
        }

        var pickerIcon: String {
            switch self {
            case .laptop: return "laptopcomputer"
            case .symbol: return "square.grid.3x3.fill"
            case .emoji:  return "face.smiling"
            case .photo:  return "photo.on.rectangle.angled"
            }
        }
    }

    /// A curated set of SF Symbol names that read well in the 88×88
    /// avatar circle. Used by the symbol picker when `kind == .symbol`.
    static let curatedSymbols: [String] = [
        "laptopcomputer",
        "desktopcomputer",
        "macbook",
        "macbook.gen2",
        "macmini",
        "macpro.gen3",
        "display",
        "keyboard",
        "cpu",
        "memorychip",
        "bolt.fill",
        "sparkles"
    ]

    /// Default symbol when switching kind = .symbol the first time.
    static var defaultSymbol: MercuryAvatarStyle { .symbol("macbook") }

    /// Default emoji when switching kind = .emoji the first time.
    static var defaultEmoji: MercuryAvatarStyle { .emoji("💻") }
}
