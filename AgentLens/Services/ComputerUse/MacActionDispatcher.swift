#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Concrete Path C dispatcher for Mac-wide Computer Use actions.
///
/// This is intentionally small: policy, approval, scope, and audit logging
/// live in `ComputerUseSessionCoordinator` / `ComputerUseRunCoordinator`;
/// this type only translates already-approved typed actions into AppKit/AX
/// operations and returns a structured result for audit/tool output.
public final class MacActionDispatcher: @unchecked Sendable {
    public enum DispatchError: Error, Sendable, Equatable {
        case missingCoordinates(String)
        case missingText
        case missingKey
        case unsupportedInspectKind(String)
    }

    private let inputController: MacInputController
    private let inspector: MacAccessibilityInspector

    public init(
        inputController: MacInputController = MacInputController(),
        inspector: MacAccessibilityInspector = MacAccessibilityInspector()
    ) {
        self.inputController = inputController
        self.inspector = inspector
    }

    public func dispatch(_ action: MacInputAction) throws -> BurnBarJSONValue {
        let elapsedMillis: Double
        switch action.kind {
        case .click:
            guard let x = action.displayX, let y = action.displayY else {
                throw DispatchError.missingCoordinates("click")
            }
            elapsedMillis = try inputController.click(x: x, y: y, button: action.mouseButton)
        case .type:
            guard let text = action.text else { throw DispatchError.missingText }
            elapsedMillis = try inputController.type(text: text)
        case .key:
            guard let key = action.key else { throw DispatchError.missingKey }
            elapsedMillis = try inputController.key(key, modifiers: action.modifiers ?? [])
        case .shortcut:
            guard let key = action.key else { throw DispatchError.missingKey }
            elapsedMillis = try inputController.shortcut(key: key, modifiers: action.modifiers ?? [])
        case .dragDrop:
            guard let startX = action.displayX,
                  let startY = action.displayY,
                  let endX = action.dragEndX,
                  let endY = action.dragEndY else {
                throw DispatchError.missingCoordinates("drag_drop")
            }
            elapsedMillis = try inputController.dragDrop(
                startX: startX,
                startY: startY,
                endX: endX,
                endY: endY
            )
        }

        return .object([
            "ok": .bool(true),
            "kind": .string(action.kind.rawValue),
            "elapsedMillis": .number(elapsedMillis)
        ])
    }

    public func inspect(_ action: MacInspectAction) throws -> BurnBarJSONValue {
        switch action.kind {
        case .accessibility:
            let snapshot: MacAccessibilityInspector.Snapshot?
            if let x = action.displayX, let y = action.displayY {
                snapshot = inspector.snapshotAtPoint(x: x, y: y)
            } else {
                let context = inspector.frontmostScopeContext()
                return .object([
                    "bundleId": context.bundleId.map(BurnBarJSONValue.string) ?? .null,
                    "windowTitle": context.windowTitle.map(BurnBarJSONValue.string) ?? .null,
                    "url": context.url.map(BurnBarJSONValue.string) ?? .null
                ])
            }

            return .object([
                "role": snapshot?.role.map(BurnBarJSONValue.string) ?? .null,
                "subrole": snapshot?.subrole.map(BurnBarJSONValue.string) ?? .null,
                "roleDescription": snapshot?.roleDescription.map(BurnBarJSONValue.string) ?? .null,
                "label": snapshot?.label.map(BurnBarJSONValue.string) ?? .null,
                "title": snapshot?.title.map(BurnBarJSONValue.string) ?? .null,
                "bundleId": snapshot?.bundleId.map(BurnBarJSONValue.string) ?? .null,
                "denyReason": inspector.denyReason(for: snapshot).map { .string($0.rawValue) } ?? .null
            ])
        }
    }

    public func currentScopeContext() -> ComputerUseScopeContext {
        inspector.frontmostScopeContext()
    }

    public func accessibilityDenyReason(at action: MacInputAction) -> ComputerUseAccessibilityDenyReason? {
        guard let x = action.displayX, let y = action.displayY else { return nil }
        return inspector.denyReason(for: inspector.snapshotAtPoint(x: x, y: y))
    }
}
#endif
