import SwiftUI

extension SettingsManager {
    var preferredSwiftUIColorScheme: ColorScheme? {
        _ = appearanceMutationVersionForPresentation
        if let modeScheme = appearance.appearanceMode.colorScheme {
            return modeScheme
        }
        return appearance.appearanceSkin == .editorial ? .light : nil
    }
}
