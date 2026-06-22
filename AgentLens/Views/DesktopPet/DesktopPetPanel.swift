import AppKit
import SwiftUI

// MARK: - Desktop Pet Panel

/// A floating, always-on-top, draggable `NSPanel` that hosts the desktop pet
/// and its chat bubble. The panel is borderless, non-activating (so it never
/// steals focus from the user's work), and click-through except for the pet
/// itself and the bubble controls.
@MainActor
final class DesktopPetPanel: NSPanel {
    private let settingsManager: SettingsManager
    private let chatController: ChatSessionController
    private var petView: DesktopPetView?

    init(settingsManager: SettingsManager, chatController: ChatSessionController) {
        self.settingsManager = settingsManager
        self.chatController = chatController

        let petSize = settingsManager.pets.petSize
        let frame = NSRect(x: 0, y: 0, width: petSize + 240, height: petSize + 80)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.canHide = false
        self.animationBehavior = .none
        self.isReleasedWhenClosed = false
        self.ignoresMouseEvents = false

        installPetView()
        applySavedPosition()

        // Observe settings changes to rebuild the view when pet kind/size changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: .petSettingsDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .petSettingsDidChange, object: nil)
    }

    @objc private func handleSettingsChange() {
        Task { @MainActor in
            self.rebuildPetView()
            self.applySavedPosition()
        }
    }

    private func installPetView() {
        let petView = DesktopPetView(
            settingsManager: settingsManager,
            chatController: chatController,
            onDismiss: { [weak self] in
                self?.dismissPet()
            },
            onOpenSettings: {
                NotificationCenter.default.post(name: .openPetSettings, object: nil)
            },
            onOpenFullChat: { [weak self] destination in
                self?.openFullChat(destination: destination)
            }
        )
        self.petView = petView
        let hostingView = NSHostingView(rootView: petView)
        hostingView.frame = self.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView
    }

    private func rebuildPetView() {
        guard let contentView = self.contentView as? NSHostingView<DesktopPetView> else {
            installPetView()
            return
        }
        let petView = DesktopPetView(
            settingsManager: settingsManager,
            chatController: chatController,
            onDismiss: { [weak self] in
                self?.dismissPet()
            },
            onOpenSettings: {
                NotificationCenter.default.post(name: .openPetSettings, object: nil)
            },
            onOpenFullChat: { [weak self] destination in
                self?.openFullChat(destination: destination)
            }
        )
        self.petView = petView
        contentView.rootView = petView
    }

    private func applySavedPosition() {
        let x = settingsManager.pets.petPositionX
        let y = settingsManager.pets.petPositionY

        guard x >= 0, y >= 0, let screen = NSScreen.main else {
            centerOnScreen()
            return
        }

        let visibleFrame = screen.visibleFrame
        let clampedX = min(max(x, visibleFrame.minX + 20), visibleFrame.maxX - 20)
        let clampedY = min(max(y, visibleFrame.minY + 20), visibleFrame.maxY - 20)
        setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let frame = self.frame
        let origin = NSPoint(
            x: visibleFrame.maxX - frame.width - 40,
            y: visibleFrame.minY + 40
        )
        setFrameOrigin(origin)
        settingsManager.pets.petPositionX = Double(origin.x)
        settingsManager.pets.petPositionY = Double(origin.y)
    }

    func dismissPet() {
        settingsManager.pets.petEnabled = false
        orderOut(nil)
    }

    func showPet() {
        if !settingsManager.pets.petEnabled { return }
        applySavedPosition()
        orderFrontRegardless()
    }

    private func openFullChat(destination: PetChatDestination) {
        switch destination {
        case .popover:
            NotificationCenter.default.post(name: .openBurnBarPopover, object: nil)
        case .dashboard:
            NotificationCenter.default.post(name: .openBurnBarDashboard, object: nil)
        }
    }

    // MARK: - Dragging via the pet view

    /// Called from the SwiftUI view when the pet is dragged. Moves the panel
    /// and persists the final position.
    func handleDrag(translation: CGSize, startOrigin: NSPoint) {
        let newOrigin = NSPoint(
            x: startOrigin.x + translation.width,
            y: startOrigin.y - translation.height
        )
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let clampedX = min(max(newOrigin.x, screenFrame.minX), screenFrame.maxX - 20)
        let clampedY = min(max(newOrigin.y, screenFrame.minY), screenFrame.maxY - 20)
        setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    func persistDraggedPosition() {
        let frame = self.frame
        settingsManager.pets.petPositionX = Double(frame.origin.x)
        settingsManager.pets.petPositionY = Double(frame.origin.y)
    }

    var panelOrigin: NSPoint { frame.origin }
}

// MARK: - Notifications

extension Notification.Name {
    static let openPetSettings = Notification.Name("com.openburnbar.pet.openPetSettings")
    static let openPetSettingsTab = Notification.Name("com.openburnbar.pet.openPetSettingsTab")
    static let openBurnBarPopover = Notification.Name("com.openburnbar.pet.openPopover")
    static let openBurnBarDashboard = Notification.Name("com.openburnbar.pet.openDashboard")
}
