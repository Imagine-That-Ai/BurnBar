import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit

extension NSNotification.Name {
    public static let deviceDidShakeNotification = NSNotification.Name("com.openburnbar.deviceDidShake")
}

public struct DeviceShakeViewModifier: ViewModifier {
    let action: () -> Void

    public func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShakeNotification)) { _ in
                action()
            }
    }
}

public extension View {
    func onShake(perform action: @escaping () -> Void) -> some View {
        self.modifier(DeviceShakeViewModifier(action: action))
    }
}
#endif
