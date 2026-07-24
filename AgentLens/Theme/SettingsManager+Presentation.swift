import SwiftUI

extension SettingsManager {
    var preferredSwiftUIColorScheme: ColorScheme? {
        _ = appearanceMutationVersionForPresentation
        // The appearance mode the user picked is the ground truth. The
        // editorial (Sun Lit) skin is light-only, but it no longer pins the
        // whole app to light: under a dark appearance the token layer resolves
        // to the aurora dark palette instead (see `AppSkin.resolved(for:)`),
        // so an explicit Dark / dark system setting is always honored.
        return appearance.appearanceMode.colorScheme
    }
}
