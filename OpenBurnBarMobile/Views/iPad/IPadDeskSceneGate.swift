import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Prevents Stage Manager “New Window” from cloning a second Inbox desk.
///
/// Extra windows are Watch only (`WindowGroup(id: "agent-watch")`). The
/// unnamed root `WindowGroup` still hosts `AuthGateView`; a second instance
/// of that group remounts auth, Hermes, and the overlay — the windowing
/// doc’s hard no. The first desk scene is retained; later desk scenes are
/// destroyed. Watch scenes register separately and are never destroyed here.
enum IPadDeskSceneRegistry {
    @MainActor
    private static var retainedDeskSceneID: String?
    @MainActor
    private static var watchSceneIDs = Set<String>()

    @MainActor
    static func registerDesk(_ scene: UIWindowScene) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let id = scene.session.persistentIdentifier
        if watchSceneIDs.contains(id) { return }
        if let retained = retainedDeskSceneID, retained != id {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
            return
        }
        retainedDeskSceneID = id
    }

    @MainActor
    static func unregisterDesk(_ scene: UIWindowScene) {
        if retainedDeskSceneID == scene.session.persistentIdentifier {
            retainedDeskSceneID = nil
        }
    }

    @MainActor
    static func registerWatch(_ scene: UIWindowScene) {
        watchSceneIDs.insert(scene.session.persistentIdentifier)
    }

    @MainActor
    static func unregisterWatch(_ scene: UIWindowScene) {
        watchSceneIDs.remove(scene.session.persistentIdentifier)
    }

    /// Pure rule for tests: a second desk session is never kept.
    static func shouldDestroyClonedDesk(
        incomingID: String,
        retainedDeskID: String?,
        watchIDs: Set<String>
    ) -> Bool {
        if watchIDs.contains(incomingID) { return false }
        guard let retainedDeskID else { return false }
        return incomingID != retainedDeskID
    }
}

/// Invisible probe that binds a SwiftUI tree to its `UIWindowScene`.
struct IPadDeskSceneProbe: UIViewRepresentable {
    enum Role {
        case desk
        case watch
    }

    let role: Role

    func makeUIView(context: Context) -> UIView {
        ProbeView(role: role)
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class ProbeView: UIView {
        let role: IPadDeskSceneProbe.Role

        init(role: IPadDeskSceneProbe.Role) {
            self.role = role
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else {
                return
            }
            switch role {
            case .desk:
                IPadDeskSceneRegistry.registerDesk(scene)
            case .watch:
                IPadDeskSceneRegistry.registerWatch(scene)
            }
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil, let scene = window?.windowScene {
                switch role {
                case .desk:
                    IPadDeskSceneRegistry.unregisterDesk(scene)
                case .watch:
                    IPadDeskSceneRegistry.unregisterWatch(scene)
                }
            }
            super.willMove(toWindow: newWindow)
        }
    }
}
