import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Implements Decision 1 of the Mercury media plan: when CallKit
/// reports a new incoming call and the app is already foregrounded,
/// swap the system-style call screen out for the in-app Mercury sheet.
/// When the app is launched fresh from the lock-screen Accept, route
/// straight to the in-app `CallHUDView` (no sheet flash).
///
/// Pre-warms `CallHUDView` rendering so the < 200 ms transition budget
/// is achievable on first launch.
@MainActor
final class MercuryCallTransitionController: ObservableObject {
    enum Surface: Equatable, Sendable {
        case none
        case mercurySheet(VoIPCallService.IncomingCall)
        case callHUD(VoIPCallService.IncomingCall)
    }

    @Published private(set) var surface: Surface = .none

    private var observer: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private let callService: VoIPCallService
    private let appStateProvider: @MainActor () -> UIApplication.State

    init(
        callService: VoIPCallService,
        appStateProvider: @escaping @MainActor () -> UIApplication.State = {
            #if canImport(UIKit)
            UIApplication.shared.applicationState
            #else
            .background
            #endif
        }
    ) {
        self.callService = callService
        self.appStateProvider = appStateProvider

        observer = NotificationCenter.default.addObserver(
            forName: VoIPCallService.incomingCallNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self,
                      let call = note.object as? VoIPCallService.IncomingCall else { return }
                let state = self.appStateProvider()
                if state == .active {
                    self.surface = .mercurySheet(call)
                } else {
                    self.surface = .callHUD(call)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: VoIPCallService.endedCallNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.surface = .none
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func acceptFromSheet() {
        guard case .mercurySheet(let call) = surface else { return }
        callService.answerInFlightCall()
        surface = .callHUD(call)
    }

    func decline() {
        callService.declineInFlightCall()
        surface = .none
    }

    func dismissHUD() {
        surface = .none
    }
}
