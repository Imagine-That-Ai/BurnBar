import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

/// Lets the user pick one of four avatar kinds (laptop / symbol /
/// emoji / photo). Expanded sub-pickers are inline so the panel feels
/// alive — no extra navigation hop.
@MainActor
struct MercuryAvatarStylePicker: View {
    @Binding var selection: MercuryAvatarStyle
    let accent: Color
    let haptics: MercuryHapticsLevel

    @State private var photoItem: PhotosPickerItem?
    @State private var photoLoadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            kindRow

            switch selection.kind {
            case .laptop:
                EmptyView()
            case .symbol:
                symbolGrid
            case .emoji:
                emojiRow
            case .photo:
                photoPickerRow
            }
        }
    }

    @ViewBuilder
    private var kindRow: some View {
        HStack(spacing: 10) {
            ForEach(MercuryAvatarStyle.Kind.allCases, id: \.self) { kind in
                kindChip(for: kind)
            }
        }
    }

    @ViewBuilder
    private func kindChip(for kind: MercuryAvatarStyle.Kind) -> some View {
        let isSelected = selection.kind == kind
        Button {
            haptics.play()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                selection = pickerDefault(for: kind, current: selection)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: kind.pickerIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : Color.white.opacity(0.75))
                Text(kind.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.12 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(accent.opacity(isSelected ? 0.6 : 0), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            ForEach(MercuryAvatarStyle.curatedSymbols, id: \.self) { name in
                Button {
                    haptics.play()
                    selection = .symbol(name)
                } label: {
                    Image(systemName: name)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(selectedSymbol == name ? accent.opacity(0.3) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            Circle().stroke(accent.opacity(selectedSymbol == name ? 0.7 : 0), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            }
        }
    }

    @ViewBuilder
    private var emojiRow: some View {
        let suggestions = ["💻", "🖥", "🍎", "🚀", "🔥", "🌙", "✨", "🛠", "🧠", "🦊"]
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { glyph in
                    Button {
                        haptics.play()
                        selection = .emoji(glyph)
                    } label: {
                        Text(glyph)
                            .font(.system(size: 26))
                            .frame(width: 40, height: 40)
                            .background(
                                Circle().fill(selectedEmoji == glyph ? accent.opacity(0.25) : Color.white.opacity(0.05))
                            )
                            .overlay(
                                Circle().stroke(accent.opacity(selectedEmoji == glyph ? 0.7 : 0), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var photoPickerRow: some View {
        let photoButtonTitle = hasPhoto ? "Change photo" : "Choose a photo"
        VStack(alignment: .leading, spacing: 8) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.fill")
                    Text(photoButtonTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(accent.opacity(0.25)))
            }
            .onChange(of: photoItem) { _, newItem in
                Task { await loadPhoto(item: newItem) }
            }
            if let photoLoadError {
                Text(photoLoadError)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.red)
            }
        }
    }

    private var selectedSymbol: String? {
        if case .symbol(let name) = selection { return name }
        return nil
    }

    private var selectedEmoji: String? {
        if case .emoji(let glyph) = selection { return glyph }
        return nil
    }

    private var hasPhoto: Bool {
        if case .photo = selection { return true }
        return false
    }

    private func pickerDefault(
        for kind: MercuryAvatarStyle.Kind,
        current: MercuryAvatarStyle
    ) -> MercuryAvatarStyle {
        switch kind {
        case .laptop: return .laptop
        case .symbol:
            if case .symbol = current { return current }
            return MercuryAvatarStyle.defaultSymbol
        case .emoji:
            if case .emoji = current { return current }
            return MercuryAvatarStyle.defaultEmoji
        case .photo:
            if case .photo = current { return current }
            return .photo(Data())
        }
    }

    @MainActor
    private func loadPhoto(item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self) else {
                photoLoadError = "Couldn't load that photo."
                return
            }
            #if canImport(UIKit)
            if let image = UIImage(data: raw),
               let compressed = downscaledJPEGData(from: image) {
                photoLoadError = nil
                selection = .photo(compressed)
            } else {
                photoLoadError = "Couldn't process that photo."
            }
            #else
            photoLoadError = nil
            selection = .photo(raw)
            #endif
        } catch {
            photoLoadError = error.localizedDescription
        }
    }

    #if canImport(UIKit)
    private func downscaledJPEGData(from image: UIImage) -> Data? {
        let maxDim: CGFloat = 256
        let scale = max(image.size.width, image.size.height) / maxDim
        let targetSize = scale > 1
            ? CGSize(width: image.size.width / scale, height: image.size.height / scale)
            : image.size
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.82)
    }
    #endif
}
