import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit

extension NSNotification.Name {
    public static let deviceDidShakeNotification = NSNotification.Name("com.openburnbar.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShakeNotification, object: nil)
        }
    }
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
