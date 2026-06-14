import SwiftUI

extension SettingsManager {
    var preferredSwiftUIColorScheme: ColorScheme? {
        _ = appearanceMutationVersionForPresentation
        // Editorial is light-locked; its paper palette should never sit on a
        // dark app appearance, regardless of the mode picker.
        if appearance.appearanceSkin == .editorial { return .light }
        return appearance.appearanceMode.colorScheme
    }
}
