import Foundation

struct LivingThemeDeepLink: Equatable, Identifiable, Sendable {
    enum Quality: String, CaseIterable, Sendable {
        case eco
        case atelier
        case cinema

        var maxFrameRate: Double {
            switch self {
            case .eco: return 20
            case .atelier: return 30
            case .cinema: return 30
            }
        }
    }

    let kernel: MobileBackdropKernel
    let quality: Quality

    var id: String { "\(kernel.rawValue):\(quality.rawValue)" }

    static func parse(_ url: URL) -> LivingThemeDeepLink? {
        guard url.scheme?.lowercased() == "burnbar",
              ["living-theme", "live-wallpaper"].contains(url.host?.lowercased() ?? "") else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let themeID = components?.queryItems?
            .first { ["theme", "kernel"].contains($0.name.lowercased()) }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let themeID, let kernel = MobileBackdropKernel(rawValue: themeID) else {
            return nil
        }

        let qualityValue = components?.queryItems?
            .first { $0.name.lowercased() == "quality" }?
            .value?
            .lowercased()
        return LivingThemeDeepLink(
            kernel: kernel,
            quality: Quality(rawValue: qualityValue ?? "") ?? .eco
        )
    }
}
