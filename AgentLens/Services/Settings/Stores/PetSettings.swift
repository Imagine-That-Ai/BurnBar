import Foundation
import Observation

// MARK: - Pet Types

/// The visual pet the user picks from Settings → Pets.
enum DesktopPetKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case emberSprite
    case mercuryDroplet
    case cosmicOwl
    case pixelCat
    case burnBarMascot
    case ghostOwl
    case sparkleFox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .emberSprite:    return "Ember Sprite"
        case .mercuryDroplet: return "Mercury Droplet"
        case .cosmicOwl:      return "Cosmic Owl"
        case .pixelCat:       return "Pixel Cat"
        case .burnBarMascot:  return "BurnBar Mascot"
        case .ghostOwl:       return "Ghost Owl"
        case .sparkleFox:     return "Sparkle Fox"
        }
    }

    var sfSymbol: String {
        switch self {
        case .emberSprite:    return "flame.fill"
        case .mercuryDroplet: return "drop.fill"
        case .cosmicOwl:      return "bird.fill"
        case .pixelCat:       return "cat.fill"
        case .burnBarMascot:  return "flame.circle.fill"
        case .ghostOwl:       return "moon.zzz.fill"
        case .sparkleFox:     return "sparkles"
        }
    }

    var accentColor: String {
        switch self {
        case .emberSprite:    return "ember"
        case .mercuryDroplet: return "hermesMercury"
        case .cosmicOwl:      return "whimsy"
        case .pixelCat:       return "teal"
        case .burnBarMascot:  return "blaze"
        case .ghostOwl:       return "frost"
        case .sparkleFox:     return "amber"
        }
    }

    var detailText: String {
        switch self {
        case .emberSprite:    return "A warm flickering flame companion."
        case .mercuryDroplet: return "A shimmering liquid-metal droplet."
        case .cosmicOwl:      return "A watchful owl from the stars."
        case .pixelCat:       return "A retro pixel-art cat."
        case .burnBarMascot:  return "The classic BurnBar flame mascot."
        case .ghostOwl:       return "A sleepy translucent owl."
        case .sparkleFox:     return "A playful fox trailing sparkles."
        }
    }
}

/// Where the ellipses button on the pet chat bubble should open the full chat.
enum PetChatDestination: String, CaseIterable, Codable, Identifiable, Hashable {
    case popover
    case dashboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .popover:   return "Menu Bar Popover"
        case .dashboard: return "Dashboard"
        }
    }

    var detailText: String {
        switch self {
        case .popover:   return "Opens the compact menu bar popover with the Hermes strip."
        case .dashboard: return "Opens the full dashboard chat workspace."
        }
    }

    var sfSymbol: String {
        switch self {
        case .popover:   return "menubar.rectangle"
        case .dashboard: return "rectangle.expand.vertical"
        }
    }
}

// MARK: - Pet Settings Store

@Observable
@MainActor
final class PetSettings {
    private let persistence: SettingsPersistenceCoordinator

    var petEnabled: Bool {
        didSet {
            persistence.set(petEnabled, forKey: "petEnabled")
            NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        }
    }

    var selectedPet: DesktopPetKind {
        didSet {
            persistence.set(selectedPet.rawValue, forKey: "petSelectedKind")
            NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        }
    }

    var petSize: Double {
        didSet {
            let clamped = min(max(petSize, 48), 128)
            guard petSize == clamped else {
                petSize = clamped
                return
            }
            persistence.set(petSize, forKey: "petSize")
            NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        }
    }

    var petPositionX: Double {
        didSet {
            persistence.set(petPositionX, forKey: "petPositionX")
            NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        }
    }

    var petPositionY: Double {
        didSet {
            persistence.set(petPositionY, forKey: "petPositionY")
            NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        }
    }

    var chatBubbleEnabled: Bool {
        didSet {
            persistence.set(chatBubbleEnabled, forKey: "petChatBubbleEnabled")
            NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        }
    }

    var preferredChatDestination: PetChatDestination {
        didSet {
            persistence.set(preferredChatDestination.rawValue, forKey: "petPreferredChatDestination")
            NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        self.petEnabled = persistence.objectExists(forKey: "petEnabled")
            ? persistence.bool(forKey: "petEnabled")
            : false
        if let raw = persistence.optionalString(forKey: "petSelectedKind"),
           let kind = DesktopPetKind(rawValue: raw) {
            self.selectedPet = kind
        } else {
            self.selectedPet = .emberSprite
        }
        self.petSize = min(max(persistence.double(forKey: "petSize", defaultValue: 72), 48), 128)
        self.petPositionX = persistence.double(forKey: "petPositionX", defaultValue: -1)
        self.petPositionY = persistence.double(forKey: "petPositionY", defaultValue: -1)
        self.chatBubbleEnabled = persistence.objectExists(forKey: "petChatBubbleEnabled")
            ? persistence.bool(forKey: "petChatBubbleEnabled")
            : true
        if let raw = persistence.optionalString(forKey: "petPreferredChatDestination"),
           let dest = PetChatDestination(rawValue: raw) {
            self.preferredChatDestination = dest
        } else {
            self.preferredChatDestination = .popover
        }
    }
}

extension Notification.Name {
    static let petSettingsDidChange = Notification.Name("com.openburnbar.pet.petSettingsDidChange")
}
