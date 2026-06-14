import SwiftUI

extension DesktopWallpaperBackground {
    var swatchColor: Color {
        switch self {
        case .macOSDesktop: return Color(red: 0.180, green: 0.455, blue: 0.930)
        case .midnight: return Color(red: 0.020, green: 0.024, blue: 0.040)
        case .amoledBlack: return Color.black
        case .graphite: return Color(red: 0.110, green: 0.115, blue: 0.125)
        case .warmEmber: return Color(red: 0.115, green: 0.065, blue: 0.045)
        case .deepIndigo: return Color(red: 0.050, green: 0.045, blue: 0.115)
        case .auroraTeal: return Color(red: 0.020, green: 0.050, blue: 0.055)
        case .sunsetCrimson: return Color(red: 0.050, green: 0.020, blue: 0.024)
        case .cyberpunkViolet: return Color(red: 0.035, green: 0.020, blue: 0.050)
        case .forestMoss: return Color(red: 0.020, green: 0.040, blue: 0.025)
        case .solarFlare: return Color(red: 0.055, green: 0.040, blue: 0.020)
        }
    }

    var swatchPreviewColors: [Color] {
        switch self {
        case .macOSDesktop:
            return [
                Color(red: 0.180, green: 0.455, blue: 0.930),
                Color(red: 0.960, green: 0.385, blue: 0.455),
                Color(red: 0.980, green: 0.720, blue: 0.255)
            ]
        case .midnight:
            return [
                Color(red: 0.018, green: 0.026, blue: 0.070),
                Color(red: 0.055, green: 0.145, blue: 0.320),
                Color(red: 0.115, green: 0.260, blue: 0.520)
            ]
        case .amoledBlack:
            return [
                Color.black,
                Color(red: 0.010, green: 0.010, blue: 0.012),
                Color(red: 0.055, green: 0.055, blue: 0.060)
            ]
        case .graphite:
            return [
                Color(red: 0.105, green: 0.112, blue: 0.128),
                Color(red: 0.270, green: 0.295, blue: 0.330),
                Color(red: 0.475, green: 0.505, blue: 0.545)
            ]
        case .warmEmber:
            return [
                Color(red: 0.115, green: 0.052, blue: 0.030),
                Color(red: 0.470, green: 0.145, blue: 0.020),
                Color(red: 0.920, green: 0.355, blue: 0.055)
            ]
        case .deepIndigo:
            return [
                Color(red: 0.045, green: 0.035, blue: 0.120),
                Color(red: 0.180, green: 0.115, blue: 0.390),
                Color(red: 0.410, green: 0.300, blue: 0.880)
            ]
        case .auroraTeal:
            return [
                Color(red: 0.015, green: 0.045, blue: 0.050),
                Color(red: 0.050, green: 0.180, blue: 0.200),
                Color(red: 0.120, green: 0.380, blue: 0.400)
            ]
        case .sunsetCrimson:
            return [
                Color(red: 0.045, green: 0.018, blue: 0.020),
                Color(red: 0.180, green: 0.055, blue: 0.070),
                Color(red: 0.420, green: 0.115, blue: 0.145)
            ]
        case .cyberpunkViolet:
            return [
                Color(red: 0.030, green: 0.015, blue: 0.045),
                Color(red: 0.150, green: 0.055, blue: 0.220),
                Color(red: 0.380, green: 0.120, blue: 0.520)
            ]
        case .forestMoss:
            return [
                Color(red: 0.015, green: 0.035, blue: 0.020),
                Color(red: 0.055, green: 0.140, blue: 0.080),
                Color(red: 0.150, green: 0.320, blue: 0.180)
            ]
        case .solarFlare:
            return [
                Color(red: 0.050, green: 0.035, blue: 0.015),
                Color(red: 0.200, green: 0.140, blue: 0.055),
                Color(red: 0.480, green: 0.340, blue: 0.120)
            ]
        }
    }

    var swatchPreviewStrokeColor: Color {
        switch self {
        case .macOSDesktop:
            return Color(red: 0.180, green: 0.455, blue: 0.930)
        case .midnight:
            return Color(red: 0.170, green: 0.335, blue: 0.650)
        case .amoledBlack:
            return Color(red: 0.910, green: 0.355, blue: 0.405)
        case .graphite:
            return Color(red: 0.570, green: 0.600, blue: 0.640)
        case .warmEmber:
            return Color(red: 0.920, green: 0.355, blue: 0.055)
        case .deepIndigo:
            return Color(red: 0.500, green: 0.380, blue: 0.960)
        case .auroraTeal:
            return Color(red: 0.120, green: 0.380, blue: 0.400)
        case .sunsetCrimson:
            return Color(red: 0.420, green: 0.115, blue: 0.145)
        case .cyberpunkViolet:
            return Color(red: 0.380, green: 0.120, blue: 0.520)
        case .forestMoss:
            return Color(red: 0.150, green: 0.320, blue: 0.180)
        case .solarFlare:
            return Color(red: 0.480, green: 0.340, blue: 0.120)
        }
    }
}
