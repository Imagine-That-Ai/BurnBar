import SwiftUI
import PhotosUI

// MARK: - UserAvatarView
//
// Reusable avatar circle that:
//  • Shows the user's Firebase photo (AsyncImage) when photoURL is set.
//  • Falls back to a coloured monogram circle (first letter of name/email).
//  • Falls back to a generic SF Symbol person icon when signed out.
//  • Optionally renders a camera badge button to trigger photo picking.
//
// Usage (read-only, e.g. Settings header):
//   UserAvatarView(photoURL: identity.photoURL, displayName: identity.displayName, size: 60)
//
// Usage (editable, e.g. Account settings):
//   UserAvatarView(photoURL: identity.photoURL, displayName: identity.displayName, size: 80,
//                  isEditable: true, onPickImage: { image in … })

struct UserAvatarView: View {
    let photoURL: URL?
    let displayName: String?
    var size: CGFloat = 60
    var isEditable: Bool = false
    var onPickImage: ((UIImage) -> Void)?

    @State private var pickerItem: PhotosPickerItem?
    @State private var isPickerPresented = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarCircle
                .frame(width: size, height: size)

            if isEditable {
                cameraBadge
            }
        }
        .photosPicker(
            isPresented: $isPickerPresented,
            selection: $pickerItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadImage(from: newItem) }
        }
    }

    // MARK: - Avatar circle

    @ViewBuilder
    private var avatarCircle: some View {
        if let photoURL {
            AsyncImage(url: photoURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                default:
                    monogramCircle
                }
            }
        } else {
            monogramCircle
        }
    }

    private var monogramCircle: some View {
        ZStack {
            Circle()
                .fill(monogramGradient)
            if let letter = monogramLetter {
                Text(letter)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Camera badge

    private var cameraBadge: some View {
        Button {
            isPickerPresented = true
        } label: {
            ZStack {
                Circle()
                    .fill(Color(.systemBackground))
                    .frame(width: badgeSize, height: badgeSize)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: badgeSize - 2, height: badgeSize - 2)
                Image(systemName: "camera.fill")
                    .font(.system(size: badgeSize * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change profile photo")
    }

    // MARK: - Helpers

    private var badgeSize: CGFloat { size * 0.38 }

    private var monogramLetter: String? {
        let source = displayName ?? ""
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return String(first).uppercased()
    }

    private var monogramGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hue: 0.06, saturation: 0.85, brightness: 0.85),
                     Color(hue: 0.04, saturation: 0.90, brightness: 0.65)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func loadImage(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else { return }
        onPickImage?(uiImage)
    }
}
