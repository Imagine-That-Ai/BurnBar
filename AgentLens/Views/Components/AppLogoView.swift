import SwiftUI

/// BurnBar brand mark from asset catalog (`AppLogo` vector).
struct AppLogoView: View {
    var size: CGFloat = 24

    var body: some View {
        Image("AppLogo")
            .resizable()
            .renderingMode(.original)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("BurnBar")
    }
}
