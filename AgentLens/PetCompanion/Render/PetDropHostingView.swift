import AppKit

// MARK: - PetDropHostingView

/// Marker + shared storage for the pet renderer views that accept file
/// drag-and-drop (the SceneKit 3D `SCNView` and the SpriteKit 2D `SKView`). Each
/// concrete subclass registers ``PetAttachmentDropDelegate/acceptableTypes`` in
/// its init and overrides the ``NSDraggingDestination`` methods, forwarding to
/// ``dropDelegate``. ``PetCompanionController`` installs the delegate on every
/// freshly mounted renderer view (alongside the click gesture) so a 2D↔3D form
/// swap keeps the drop target live.
///
/// The protocol is `@MainActor` and `AnyObject` because the hosting views own
/// AppKit view state, which is main-thread-only — matching the app's "AppKit
/// only at the shell, on the main actor" convention.
@MainActor
protocol PetDropHostingView: AnyObject {
    /// The drop delegate installed by ``PetCompanionController``. `nil` until the
    /// controller wires it (and after unmount), so an unconfigured view is a
    /// drop-through rather than a silent no-op.
    var dropDelegate: PetAttachmentDropDelegate? { get set }

    /// Register the pasteboard types the pet accepts with AppKit's drag system.
    /// The controller calls this after installing the delegate so the view
    /// participates in a drag session only when wired. Implemented by the
    /// concrete view subclasses (`InteractivePetSceneView`, `InteractivePetSKView`)
    /// which forward to `registerForDraggedTypes`.
    func registerPetDropTypes()

    /// The right-click handler installed by ``PetCompanionController``; `nil`
    /// until the controller wires it so an unconfigured view ignores right-
    /// clicks. Implemented as a closure so the non-NSObject controller can drive
    /// an elegant context menu without the view owning AppKit menu state.
    var rightClickHandler: ((NSView, NSEvent) -> Void)? { get set }
}

// MARK: - NSDraggingDestination forwarding

extension PetDropHostingView where Self: NSView {

    /// Shared `draggingEntered` / `draggingUpdated` implementation: ask the
    /// delegate whether the drop point hits visible pet content and carries an
    /// acceptable file/image. Returns `[]` (drop-through) when no delegate is
    /// installed so AppKit forwards the drag to the window beneath the pet.
    func petDropEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let delegate = dropDelegate else { return [] }
        return delegate.acceptsDrag(info: AnyDragInfo(sender), in: self)
    }

    /// Shared `performDragOperation` implementation: hand the pasteboard to the
    /// delegate to stage every accepted file/image. Returns `false` when no
    /// delegate is installed so AppKit hands the drop to the window beneath.
    func petDropPerform(_ sender: NSDraggingInfo) -> Bool {
        guard let delegate = dropDelegate else { return false }
        return delegate.performDrag(info: AnyDragInfo(sender))
    }
}

// MARK: - AnyDragInfo

/// Adapter that bridges an AppKit `NSDraggingInfo` into the testable
/// ``PetDragInfo`` surface. Swift doesn't recognize the `extension NSDraggingInfo:
/// PetDragInfo {}` conformance when the value arrives as the `any NSDraggingInfo`
/// existential from an AppKit override, so the bridge methods above wrap the
/// session in this struct instead of relying on the protocol conformance.
@MainActor
private struct AnyDragInfo: PetDragInfo {
    let pasteboard: NSPasteboard
    let location: NSPoint

    init(_ info: NSDraggingInfo) {
        self.pasteboard = info.draggingPasteboard
        self.location = info.draggingLocation
    }

    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingLocation: NSPoint { location }
}
