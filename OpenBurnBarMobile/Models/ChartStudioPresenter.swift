import SwiftUI
import OpenBurnBarCore

// MARK: - Chart Studio Presenter
//
// Global state that lets Chart Studio be opened, minimized into a floating
// FAB that follows the user across tabs, and restored to full-screen.
//
// The actual canvas content (digest, hermesService) is owned by Pulse — this
// presenter just tracks "is Studio currently presented?" and hands the
// snapshot back when the user taps the FAB.

@Observable
@MainActor
final class ChartStudioPresenter {

    /// Snapshot of what Studio needs to re-open. We capture the digest at the
    /// moment the user opens Studio so the FAB can keep showing the same
    /// data even if Pulse refreshes underneath.
    struct Snapshot: Equatable {
        let digest: TrendDataDigest
        let openedAt: Date

        // `Equatable` only checks identity-relevant fields.
        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.openedAt == rhs.openedAt
        }
    }

    enum Mode: Equatable {
        case hidden
        case fullscreen
        case minimized
    }

    private(set) var mode: Mode = .hidden
    private(set) var snapshot: Snapshot?

    // Persisted FAB position (saved across launches)
    var fabOffset: CGSize = ChartStudioPresenter.loadFabOffset() {
        didSet { Self.persistFabOffset(fabOffset) }
    }

    func present(digest: TrendDataDigest) {
        snapshot = Snapshot(digest: digest, openedAt: Date())
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            mode = .fullscreen
        }
    }

    func minimize() {
        guard mode == .fullscreen else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            mode = .minimized
        }
    }

    func restore() {
        guard mode == .minimized else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            mode = .fullscreen
        }
    }

    func dismiss() {
        withAnimation(.easeInOut(duration: 0.25)) {
            mode = .hidden
        }
        // Drop the snapshot after the animation; nothing on the screen
        // references it once we're hidden.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if self.mode == .hidden { self.snapshot = nil }
        }
    }

    // MARK: - Persistence

    private static let fabOffsetKey = "chartStudio.fabOffset"

    private static func loadFabOffset() -> CGSize {
        let defaults = UserDefaults.standard
        let x = defaults.object(forKey: "\(fabOffsetKey).x") as? Double ?? 0
        let y = defaults.object(forKey: "\(fabOffsetKey).y") as? Double ?? -120
        return CGSize(width: x, height: y)
    }

    private static func persistFabOffset(_ offset: CGSize) {
        let defaults = UserDefaults.standard
        defaults.set(offset.width, forKey: "\(fabOffsetKey).x")
        defaults.set(offset.height, forKey: "\(fabOffsetKey).y")
    }
}

// MARK: - Environment

private struct ChartStudioPresenterKey: EnvironmentKey {
    @MainActor static var defaultValue: ChartStudioPresenter? { nil }
}

extension EnvironmentValues {
    var chartStudioPresenter: ChartStudioPresenter? {
        get { self[ChartStudioPresenterKey.self] }
        set { self[ChartStudioPresenterKey.self] = newValue }
    }
}
