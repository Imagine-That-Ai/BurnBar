import SwiftUI
import AVKit

/// Local self-view PiP — 88×128, draggable to corners, mercury hairline.
@MainActor
struct SelfPiPView: View {
    @State private var dragOffset: CGSize = .zero
    @State private var anchor: CornerAnchor = .topRight

    let renderImage: () -> AnyView

    enum CornerAnchor: Equatable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    var body: some View {
        GeometryReader { proxy in
            renderImage()
                .frame(width: 88, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(borderGradient, lineWidth: 1)
                )
                .position(position(in: proxy.size))
                .offset(dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            anchor = nearestCorner(for: value.location, in: proxy.size)
                            withAnimation(.snappy(duration: 0.18)) {
                                dragOffset = .zero
                            }
                        }
                )
        }
    }

    private func position(in size: CGSize) -> CGPoint {
        let inset: CGFloat = 16 + 44
        switch anchor {
        case .topLeft: return CGPoint(x: inset, y: inset)
        case .topRight: return CGPoint(x: size.width - inset, y: inset)
        case .bottomLeft: return CGPoint(x: inset, y: size.height - inset)
        case .bottomRight: return CGPoint(x: size.width - inset, y: size.height - inset)
        }
    }

    private func nearestCorner(for point: CGPoint, in size: CGSize) -> CornerAnchor {
        let mx = size.width / 2
        let my = size.height / 2
        if point.x < mx && point.y < my { return .topLeft }
        if point.x >= mx && point.y < my { return .topRight }
        if point.x < mx && point.y >= my { return .bottomLeft }
        return .bottomRight
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.78, green: 0.74, blue: 0.69), Color(red: 0.63, green: 0.67, blue: 0.73)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

@MainActor
final class CallHUDState: ObservableObject {
    @Published var startedAt: Date = Date()
    @Published var isMicMuted: Bool = false
    @Published var isCameraMuted: Bool = false
    @Published var isSharingScreen: Bool = false
    @Published var pulse: Bool = false

    var formattedDuration: String {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
