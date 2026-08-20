import SwiftUI
import OpenBurnBarRecap
import Foundation
import CoreGraphics
import CoreText
import OpenBurnBarKernel
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// Particle color derivation, color-driver state, and provider-logo coloring.
// Extracted from SwarmCanvasView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension SwarmSimulation {

    // Color key encoding: `bucket * 100 + tier`, where `tier` is 0…15 (a full
    // 16-step opacity ramp, max ~0.98) and `bucket` selects the palette color.
    // Buckets 0–3 are the regular palette; 4–8 are router-flow roles; 9–15 are
    // BurnBar logo roles. Using a ×100 stride keeps tiers (<16) from colliding.
    func colorKey(for p: Particle) -> Int {
        let tier = min(15, max(0, Int(p.opacity * 16)))
        if case .shapeProviderLogo = mode, let role = p.role {
            switch role {
            case "logo-flame-inner": return 9 * 100 + tier
            case "logo-flame-outer": return 10 * 100 + tier
            case "logo-flame-spark": return 11 * 100 + tier
            default:                 return 9 * 100 + tier
            }
        }
        if mode == .shapeRouterFlow, let role = p.role {
            switch role {
            case "gateway":              return 4 * 100 + tier
            case "path-1", "target-1":   return 5 * 100 + tier
            case "path-2", "target-2":   return 6 * 100 + tier
            case "path-3", "target-3":   return 7 * 100 + tier
            default:                     return 8 * 100 + tier
            }
        }
        if mode == .shapeBurnBarLogo || mode == .shapeGrok, let role = p.role {
            switch role {
            case "logo-flame-inner": return 9 * 100 + tier
            case "logo-flame-outer": return 10 * 100 + tier
            case "logo-flame-spark": return 11 * 100 + tier
            case "logo-bar-1":       return 12 * 100 + tier
            case "logo-bar-2":       return 13 * 100 + tier
            case "logo-bar-3":       return 14 * 100 + tier
            case "logo-bar-4":       return 10 * 100 + tier
            case "logo-bar-5":       return 15 * 100 + tier
            default:                 return 10 * 100 + tier
            }
        }
        return colorBucket(p: p) * 100 + tier
    }

    func colorBucket(p: Particle) -> Int {
        if p.colorIndex < 0.08 { return 0 }       // whimsy
        if p.colorIndex < 0.35 { return 1 }       // ember
        if p.colorIndex < 0.62 { return 2 }       // amber
        return 3                                   // blaze
    }

    func rgbaFromKey(_ key: Int, uiMode: UIMode = .standard) -> RGBA {
        let bucket = key / 100
        let tier = key % 100
        // In light mode, lift the opacity floor a touch so the deeper palette
        // still reads against the warm off-white backdrop.
        let base = Double(tier) / 16.0 + 0.04        // ~0.04 … 0.98
        let opacity = renderScheme == .dark ? base : min(1.0, base + 0.08)
        let dark = renderScheme == .dark

        if uiMode == .cooking {
            let pitayaPink = RGBA(r: 1.0, g: 0.165, b: 0.52, a: opacity)
            let mangoOrange = RGBA(r: 1.0, g: 0.647, b: 0.0, a: opacity)
            let electricLime = RGBA(r: 0.224, g: 1.0, b: 0.078, a: opacity)
            let kiwiTurquoise = RGBA(r: 0.0, g: 0.96, b: 1.0, a: opacity)

            let sparkleWhite = RGBA(r: 1.0, g: 1.0, b: 1.0, a: min(1.0, opacity * 1.65))
            let cherryPink = RGBA(r: 1.0, g: 0.078, b: 0.576, a: min(1.0, opacity * 1.55))

            switch bucket {
            case 0: return kiwiTurquoise
            case 1: return electricLime
            case 2: return mangoOrange
            case 3: return pitayaPink
            case 4: return RGBA(r: kiwiTurquoise.r, g: kiwiTurquoise.g, b: kiwiTurquoise.b, a: min(1.0, opacity * 1.6))
            case 5: return RGBA(r: pitayaPink.r, g: pitayaPink.g, b: pitayaPink.b, a: min(1.0, opacity * 1.5))
            case 6: return RGBA(r: mangoOrange.r, g: mangoOrange.g, b: mangoOrange.b, a: min(1.0, opacity * 1.5))
            case 7: return RGBA(r: electricLime.r, g: electricLime.g, b: electricLime.b, a: min(1.0, opacity * 1.5))
            case 9: return sparkleWhite
            case 10: return pitayaPink
            case 11: return electricLime
            case 12: return mangoOrange
            case 13: return electricLime
            case 14: return cherryPink
            case 15: return kiwiTurquoise
            default: return pitayaPink
            }
        }

        let whimsy: RGBA
        let ember: RGBA
        let amber: RGBA
        let blaze: RGBA

        let logoGold: RGBA
        let logoYellow: RGBA
        let logoOrange: RGBA
        let logoRed: RGBA
        let logoCrimson: RGBA

        switch colorPalette {
        case .defaultEmber:
            whimsy = dark ? RGBA(r: 0.50, g: 0.50, b: 1.00, a: opacity) : RGBA(r: 0.32, g: 0.30, b: 0.86, a: opacity)
            ember  = dark ? RGBA(r: 0.98, g: 0.42, b: 0.024, a: opacity) : RGBA(r: 0.80, g: 0.30, b: 0.0, a: opacity)
            amber  = dark ? RGBA(r: 0.99, g: 0.768, b: 0.172, a: opacity) : RGBA(r: 0.78, g: 0.52, b: 0.0, a: opacity)
            blaze  = dark ? RGBA(r: 0.93, g: 0.094, b: 0.012, a: opacity) : RGBA(r: 0.74, g: 0.07, b: 0.0, a: opacity)

            logoGold = dark ? RGBA(r: 1.00, g: 0.78, b: 0.15, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.80, g: 0.54, b: 0.00, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 1.00, g: 0.64, b: 0.11, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.82, g: 0.40, b: 0.00, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 0.96, g: 0.36, b: 0.04, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.76, g: 0.22, b: 0.00, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 0.90, g: 0.11, b: 0.08, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.68, g: 0.06, b: 0.04, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.69, g: 0.07, b: 0.15, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.50, g: 0.04, b: 0.09, a: min(1.0, opacity * 1.6))

        case .auroraTeal:
            whimsy = dark ? RGBA(r: 0.54, g: 0.17, b: 0.89, a: opacity) : RGBA(r: 0.44, g: 0.07, b: 0.79, a: opacity)
            ember  = dark ? RGBA(r: 0.0, g: 0.5, b: 0.5, a: opacity) : RGBA(r: 0.0, g: 0.4, b: 0.4, a: opacity)
            amber  = dark ? RGBA(r: 0.0, g: 0.96, b: 1.0, a: opacity) : RGBA(r: 0.0, g: 0.76, b: 0.80, a: opacity)
            blaze  = dark ? RGBA(r: 0.0, g: 1.0, b: 0.5, a: opacity) : RGBA(r: 0.0, g: 0.8, b: 0.4, a: opacity)

            logoGold = dark ? RGBA(r: 0.0, g: 1.0, b: 0.64, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.0, g: 0.8, b: 0.50, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 0.0, g: 0.96, b: 1.0, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.0, g: 0.76, b: 0.80, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 0.0, g: 0.42, b: 0.42, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.0, g: 0.32, b: 0.32, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 0.64, g: 0.40, b: 1.0, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.50, g: 0.30, b: 0.86, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.42, g: 0.0, b: 0.7, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.32, g: 0.0, b: 0.56, a: min(1.0, opacity * 1.6))

        case .sunsetCrimson:
            whimsy = dark ? RGBA(r: 0.29, g: 0.0, b: 0.51, a: opacity) : RGBA(r: 0.22, g: 0.0, b: 0.41, a: opacity)
            ember  = dark ? RGBA(r: 1.0, g: 0.08, b: 0.58, a: opacity) : RGBA(r: 0.8, g: 0.04, b: 0.46, a: opacity)
            amber  = dark ? RGBA(r: 1.0, g: 0.27, b: 0.0, a: opacity) : RGBA(r: 0.8, g: 0.18, b: 0.0, a: opacity)
            blaze  = dark ? RGBA(r: 0.7, g: 0.13, b: 0.13, a: opacity) : RGBA(r: 0.56, g: 0.08, b: 0.08, a: opacity)

            logoGold = dark ? RGBA(r: 1.0, g: 0.67, b: 0.2, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.8, g: 0.51, b: 0.1, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 1.0, g: 0.77, b: 0.62, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.8, g: 0.59, b: 0.46, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 1.0, g: 0.2, b: 0.5, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.8, g: 0.12, b: 0.38, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 0.49, g: 0.15, b: 0.8, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.38, g: 0.08, b: 0.64, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.5, g: 0.0, b: 0.12, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.38, g: 0.0, b: 0.08, a: min(1.0, opacity * 1.6))

        case .cyberpunkViolet:
            whimsy = dark ? RGBA(r: 0.0, g: 0.9, b: 1.0, a: opacity) : RGBA(r: 0.0, g: 0.7, b: 0.8, a: opacity)
            ember  = dark ? RGBA(r: 0.58, g: 0.0, b: 0.83, a: opacity) : RGBA(r: 0.46, g: 0.0, b: 0.68, a: opacity)
            amber  = dark ? RGBA(r: 1.0, g: 0.0, b: 1.0, a: opacity) : RGBA(r: 0.8, g: 0.0, b: 0.8, a: opacity)
            blaze  = dark ? RGBA(r: 1.0, g: 0.0, b: 0.5, a: opacity) : RGBA(r: 0.8, g: 0.0, b: 0.38, a: opacity)

            logoGold = dark ? RGBA(r: 1.0, g: 0.0, b: 0.5, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.8, g: 0.0, b: 0.38, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 0.0, g: 1.0, b: 1.0, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.0, g: 0.8, b: 0.8, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 0.54, g: 0.0, b: 1.0, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.42, g: 0.0, b: 0.8, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 1.0, g: 0.0, b: 1.0, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.8, g: 0.0, b: 0.8, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.0, g: 0.0, b: 0.54, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.0, g: 0.0, b: 0.42, a: min(1.0, opacity * 1.6))

        case .forestMoss:
            whimsy = dark ? RGBA(r: 0.56, g: 0.74, b: 0.56, a: opacity) : RGBA(r: 0.46, g: 0.62, b: 0.46, a: opacity)
            ember  = dark ? RGBA(r: 0.13, g: 0.55, b: 0.13, a: opacity) : RGBA(r: 0.08, g: 0.44, b: 0.08, a: opacity)
            amber  = dark ? RGBA(r: 1.0, g: 0.75, b: 0.0, a: opacity) : RGBA(r: 0.8, g: 0.6, b: 0.0, a: opacity)
            blaze  = dark ? RGBA(r: 0.82, g: 0.41, b: 0.12, a: opacity) : RGBA(r: 0.68, g: 0.32, b: 0.08, a: opacity)

            logoGold = dark ? RGBA(r: 0.85, g: 0.65, b: 0.13, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.68, g: 0.51, b: 0.08, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 0.68, g: 1.0, b: 0.18, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.54, g: 0.8, b: 0.1, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 0.72, g: 0.45, b: 0.2, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.58, g: 0.35, b: 0.14, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 0.0, g: 0.39, b: 0.0, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.0, g: 0.3, b: 0.0, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.29, g: 0.02, b: 0.02, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.22, g: 0.01, b: 0.01, a: min(1.0, opacity * 1.6))

        case .solarFlare:
            whimsy = dark ? RGBA(r: 1.0, g: 0.97, b: 0.86, a: opacity) : RGBA(r: 0.9, g: 0.87, b: 0.76, a: opacity)
            ember  = dark ? RGBA(r: 1.0, g: 0.84, b: 0.0, a: opacity) : RGBA(r: 0.8, g: 0.67, b: 0.0, a: opacity)
            amber  = dark ? RGBA(r: 1.0, g: 0.55, b: 0.0, a: opacity) : RGBA(r: 0.8, g: 0.44, b: 0.0, a: opacity)
            blaze  = dark ? RGBA(r: 1.0, g: 0.19, b: 0.0, a: opacity) : RGBA(r: 0.8, g: 0.12, b: 0.0, a: opacity)

            logoGold = dark ? RGBA(r: 1.0, g: 1.0, b: 0.88, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.88, g: 0.88, b: 0.76, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 1.0, g: 0.84, b: 0.0, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.8, g: 0.67, b: 0.0, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 1.0, g: 0.27, b: 0.0, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.8, g: 0.18, b: 0.0, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 0.86, g: 0.08, b: 0.24, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.68, g: 0.04, b: 0.18, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.36, g: 0.0, b: 0.0, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.26, g: 0.0, b: 0.0, a: min(1.0, opacity * 1.6))
        }

        switch bucket {
        case 0: return whimsy
        case 1: return ember
        case 2: return amber
        case 3: return blaze
        case 4: return RGBA(r: whimsy.r, g: whimsy.g, b: whimsy.b, a: min(1.0, opacity * 1.6))   // gateway
        case 5: return RGBA(r: blaze.r, g: blaze.g, b: blaze.b, a: min(1.0, opacity * 1.5))    // throttled
        case 6: return RGBA(r: amber.r, g: amber.g, b: amber.b, a: min(1.0, opacity * 1.5))    // active backup
        case 7: return RGBA(r: ember.r, g: ember.g, b: ember.b, a: min(1.0, opacity * 1.5))    // standby
        case 9: return logoGold
        case 10: return logoOrange
        case 11: return logoYellow
        case 12: return RGBA(r: logoGold.r, g: logoGold.g, b: logoGold.b, a: min(1.0, opacity * 1.45))
        case 13: return RGBA(r: logoYellow.r, g: logoYellow.g, b: logoYellow.b, a: min(1.0, opacity * 1.5))
        case 14: return logoRed
        case 15: return logoCrimson
        default: return RGBA(r: blaze.r, g: blaze.g, b: blaze.b, a: opacity * 0.35)            // dim bg
        }
    }

    func colorFromKey(_ key: Int, uiMode: UIMode = .standard) -> Color {
        rgbaFromKey(key, uiMode: uiMode).color
    }

    func colorFor(particle p: Particle, uiMode: UIMode = .standard) -> Color {
        colorFromKey(colorKey(for: p), uiMode: uiMode)
    }

    func refreshResolvedLogoColorsIfNeeded(for scheme: ColorScheme) {
        guard resolvedLogoColorPalette != colorPalette || resolvedLogoColorScheme != scheme else { return }
        for index in particles.indices {
            refreshResolvedLogoColor(at: index, scheme: scheme)
        }
        resolvedLogoColorPalette = colorPalette
        resolvedLogoColorScheme = scheme
    }

    func refreshResolvedLogoColor(at index: Int, scheme: ColorScheme) {
        guard let provider = particles[index].logoProvider, let role = particles[index].role else {
            particles[index].resolvedLogoColor = nil
            return
        }

        particles[index].resolvedLogoColor = Self.colorForProvider(
            provider,
            under: colorPalette,
            role: role,
            toneSeed: particles[index].toneSeed ?? Self.flameToneSeed(for: particles[index], at: index),
            colorScheme: scheme,
            sourceLogoColor: particles[index].logoColor
        )
    }

    func resolvedColor(for p: Particle, at index: Int, isBatteryThrottled: Bool = false, uiMode: UIMode = .standard) -> Color {
        if let providerLogoRGBA = resolvedProviderLogoRGBA(for: p, at: index) {
            var intensity = 1.0
            if let driver = colorDriver, driver.mode == .active {
                intensity = driver.intensityMultiplier
            }
            if isBatteryThrottled {
                intensity *= 0.5
            }
            return Color(
                red: providerLogoRGBA.r,
                green: providerLogoRGBA.g,
                blue: providerLogoRGBA.b
            )
            .opacity(providerLogoRGBA.a * intensity)
        }

        // Data-driven color path (active session only)
        if let driver = colorDriver, driver.mode == .active {
            if let rgba = resolvedDriverRGBA(driver, for: p, at: index) {
                var intensity = driver.intensityMultiplier
                if isBatteryThrottled {
                    intensity *= 0.5 // scale down intensity on battery
                }
                let effectiveOpacity = p.opacity * intensity

                // Smooth transition from previous color
                if colorTransitionProgress < 1.0,
                   index < previousColors.count,
                   let prev = previousColors[index] {
                    let t = colorTransitionProgress
                    let r = prev.r * (1 - t) + rgba.r * t
                    let g = prev.g * (1 - t) + rgba.g * t
                    let b = prev.b * (1 - t) + rgba.b * t
                    return Color(red: r, green: g, blue: b).opacity(effectiveOpacity)
                }

                return Color(red: rgba.r, green: rgba.g, blue: rgba.b).opacity(effectiveOpacity)
            }
        }

        // Fallback to original palette (when idle or driver nil)
        let fallbackRGBA = rgbaFromKey(colorKey(for: p), uiMode: uiMode)
        var intensity = 1.0
        if isBatteryThrottled {
            intensity *= 0.5
        }

        // Smooth transition from previous color (if transitioning back to idle)
        if colorTransitionProgress < 1.0,
           index < previousColors.count,
           let prev = previousColors[index] {
            let t = colorTransitionProgress
            let r = prev.r * (1 - t) + fallbackRGBA.r * t
            let g = prev.g * (1 - t) + fallbackRGBA.g * t
            let b = prev.b * (1 - t) + fallbackRGBA.b * t
            return Color(red: r, green: g, blue: b).opacity(fallbackRGBA.a * intensity)
        }

        return Color(red: fallbackRGBA.r, green: fallbackRGBA.g, blue: fallbackRGBA.b).opacity(fallbackRGBA.a * intensity)
    }

    /// Numeric (`RGBA`) form of ``resolvedColor(for:at:isBatteryThrottled:uiMode:)``,
    /// used by the substrate layer so ports get parse-free sRGB channels with the
    /// same driver / palette / scheme / transition logic the dot loop uses. Alpha
    /// already folds in the effective opacity, matching the painted dot exactly.
    func resolvedRGBA(for p: Particle, at index: Int, isBatteryThrottled: Bool = false, uiMode: UIMode = .standard) -> RGBA {
        if let providerLogoRGBA = resolvedProviderLogoRGBA(for: p, at: index) {
            var intensity = 1.0
            if let driver = colorDriver, driver.mode == .active {
                intensity = driver.intensityMultiplier
            }
            if isBatteryThrottled { intensity *= 0.5 }
            return RGBA(r: providerLogoRGBA.r, g: providerLogoRGBA.g, b: providerLogoRGBA.b,
                        a: (providerLogoRGBA.a * intensity).clamped(to: 0...1))
        }

        if let driver = colorDriver, driver.mode == .active {
            if let rgba = resolvedDriverRGBA(driver, for: p, at: index) {
                var intensity = driver.intensityMultiplier
                if isBatteryThrottled { intensity *= 0.5 }
                let effectiveOpacity = (p.opacity * intensity).clamped(to: 0...1)
                if colorTransitionProgress < 1.0, index < previousColors.count, let prev = previousColors[index] {
                    let t = colorTransitionProgress
                    return RGBA(r: prev.r * (1 - t) + rgba.r * t,
                                g: prev.g * (1 - t) + rgba.g * t,
                                b: prev.b * (1 - t) + rgba.b * t,
                                a: effectiveOpacity)
                }
                return RGBA(r: rgba.r, g: rgba.g, b: rgba.b, a: effectiveOpacity)
            }
        }

        let fallbackRGBA = rgbaFromKey(colorKey(for: p), uiMode: uiMode)
        var intensity = 1.0
        if isBatteryThrottled { intensity *= 0.5 }
        if colorTransitionProgress < 1.0, index < previousColors.count, let prev = previousColors[index] {
            let t = colorTransitionProgress
            return RGBA(r: prev.r * (1 - t) + fallbackRGBA.r * t,
                        g: prev.g * (1 - t) + fallbackRGBA.g * t,
                        b: prev.b * (1 - t) + fallbackRGBA.b * t,
                        a: (fallbackRGBA.a * intensity).clamped(to: 0...1))
        }
        return RGBA(r: fallbackRGBA.r, g: fallbackRGBA.g, b: fallbackRGBA.b,
                    a: (fallbackRGBA.a * intensity).clamped(to: 0...1))
    }

    func resolvedDriverRGBA(_ driver: SwarmColorDriver, for p: Particle, at index: Int) -> RGBA? {
        if let providerLogoRGBA = resolvedProviderLogoRGBA(for: p, at: index) {
            return providerLogoRGBA
        }

        if mode == .shapeBurnBarLogo,
           let role = p.role,
           Self.isLogoFlameRole(role) {
            return driver.resolveFlameTone(
                for: p.colorIndex,
                toneSeed: Self.flameToneSeed(for: p, at: index),
                role: role
            )
        }

        return driver.resolveColor(for: p.colorIndex)
    }

    static func isLogoFlameRole(_ role: String) -> Bool {
        role.hasPrefix("logo-flame-")
    }

    static func flameToneSeed(for p: Particle, at index: Int) -> Double {
        if let toneSeed = p.toneSeed {
            return toneSeed
        }
        return flameToneSeed(
            role: p.role,
            flowProgress: p.flowProgress,
            colorIndex: p.colorIndex,
            index: index
        )
    }

    static func flameToneSeed(role: String?, flowProgress: Double, colorIndex: Double, index: Int) -> Double {
        let roleShift: Double
        switch role {
        case "logo-flame-inner":
            roleShift = 0.31
        case "logo-flame-spark":
            roleShift = 0.67
        default:
            roleShift = 0.13
        }

        let mixed = flowProgress * 1.618_033_988_75
            + colorIndex * 0.271_828_182_84
            + Double(index % 97) * 0.010_309_278
            + roleShift
        return mixed - floor(mixed)
    }

    func setExcludeBrandShapes(_ exclude: Bool) {
        guard exclude != excludeBrandShapes else { return }
        excludeBrandShapes = exclude
        modes = SwarmFormationMode.defaultCycle(for: enabledProviderGlyphs, excludeBrandShapes: exclude)
        cycleIndex = min(cycleIndex, max(0, modes.count - 1))

        if !assignFirstProviderModeForProviderOnlyCycle() {
            switch mode {
            case .shapeDollar, .shapeCode, .shapeBurnBarLogo, .shapeRings, .shapeRouterFlow:
                assignMode(.swarm)
            default:
                break
            }
        }

        shouldResetCycleTimer = true
    }

    func setEnabledProviderGlyphs(_ providers: [AgentProvider]) {
        let normalizedProviders = SwarmProviderGlyphSelection.normalized(providers)
        guard normalizedProviders != enabledProviderGlyphs else { return }

        enabledProviderGlyphs = normalizedProviders
        modes = SwarmFormationMode.defaultCycle(for: normalizedProviders, excludeBrandShapes: excludeBrandShapes)
        cycleIndex = min(cycleIndex, max(0, modes.count - 1))

        if colorDriver?.mode == .active {
            let activeProvidersList = filteredEnabledProviders(colorDriver?.activeProviders ?? [])
            assignMode(activeProvidersList.isEmpty ? .swarm : .shapeProviderLogo(activeProvidersList))
        } else if assignFirstProviderModeForProviderOnlyCycle() {
            // The provider glyph toggle is a visual control; a non-empty selection
            // should materialize immediately on provider-forward backgrounds.
        } else if case .shapeProviderLogo(let providers) = mode {
            let visibleProviders = filteredEnabledProviders(providers)
            assignMode(visibleProviders.isEmpty ? .swarm : .shapeProviderLogo(visibleProviders))
        } else if mode == .shapeGrok, !normalizedProviders.contains(.xAI) {
            assignMode(.swarm)
        }

        shouldResetCycleTimer = true
    }

    private func assignFirstProviderModeForProviderOnlyCycle() -> Bool {
        guard excludeBrandShapes,
              let firstMode = modes.first,
              firstMode != .swarm else {
            return false
        }
        cycleIndex = 0
        assignMode(firstMode)
        return true
    }

    /// Updates the color driver and triggers a smooth transition.
    public func setColorDriver(_ driver: SwarmColorDriver?) {
        // Snapshot current resolved colors for transition.
        previousColors = particles.enumerated().map { index, p in
            if let d = colorDriver, d.mode == .active {
                return resolvedDriverRGBA(d, for: p, at: index)
            } else {
                return rgbaFromKey(colorKey(for: p))
            }
        }

        let wasActive = colorDriver?.mode == .active
        let wasIdle = colorDriver?.mode == .idle || colorDriver == nil
        let nowActive = driver?.mode == .active

        let activeProvidersList = filteredEnabledProviders(driver?.activeProviders ?? [])

        colorDriver = driver
        colorTransitionProgress = 0.0

        // Fast ignition when going idle → active.
        if wasIdle && nowActive {
            activeTransitionDuration = Self.ignitionTransitionDuration
        } else {
            activeTransitionDuration = Self.colorTransitionDuration
        }

        // Shape morph control
        if nowActive {
            assignMode(activeProvidersList.isEmpty ? .swarm : .shapeProviderLogo(activeProvidersList))
        } else if wasActive && !nowActive {
            // Revert back to swarm when cooling down to idle
            assignMode(.swarm)
            cycleIndex = 0
            shouldResetCycleTimer = true
        }
    }

    public func setAutoCyclingEnabled(_ enabled: Bool) {
        isAutoCyclingEnabled = enabled
        shouldResetCycleTimer = true
    }

    func forceCycleShape() -> SwarmFormationMode {
        let inspectionCycle = SwarmFormationMode.inspectionCycle(for: enabledProviderGlyphs)
        guard !inspectionCycle.isEmpty else { return mode }

        let currentIdx = inspectionCycle.firstIndex(where: { $0 == mode }) ?? -1
        let nextIdx = (currentIdx + 1) % inspectionCycle.count
        let nextMode = inspectionCycle[nextIdx]
        assignMode(nextMode)

        // Reset the auto-cycling timer so the shape stays for visual inspection
        shouldResetCycleTimer = true
        return nextMode
    }

    func filteredEnabledProviders(_ providers: [AgentProvider]) -> [AgentProvider] {
        let enabled = Set(enabledProviderGlyphs)
        guard !enabled.isEmpty else { return [] }

        var seen = Set<AgentProvider>()
        return providers.filter { provider in
            enabled.contains(provider) && seen.insert(provider).inserted
        }
    }

    static func providerLogoSlots(count: Int, width: Double, height: Double) -> [ProviderLogoSlot] {
        guard count > 0 else { return [] }

        if count == 1 {
            return [
                ProviderLogoSlot(
                    centerX: width > 960 ? width * 0.74 : width * 0.5,
                    centerY: width > 960 ? height * 0.30 : height * 0.24,
                    scale: min(width, height) * 0.34
                )
            ]
        }

        let maxColumns: Int
        if width >= 1320 {
            maxColumns = 5
        } else if width >= 920 {
            maxColumns = 4
        } else {
            maxColumns = 2
        }
        let columns = min(count, maxColumns)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let xStep = min(300.0, max(180.0, width * 0.78 / Double(max(columns - 1, 1))))
        let yStep = min(210.0, max(130.0, height * 0.44 / Double(max(rows - 1, 1))))
        let gridHeight = yStep * Double(max(rows - 1, 0))
        let gridCenterY = height * (rows > 1 ? 0.40 : 0.34)
        let scale = min(
            min(width, height) * 0.32,
            max(110.0, min(xStep, rows > 1 ? yStep : height * 0.32) * 0.72)
        )

        var slots: [ProviderLogoSlot] = []
        slots.reserveCapacity(count)
        for index in 0..<count {
            let row = index / columns
            let column = index % columns
            let rowCount = min(columns, count - row * columns)
            let rowWidth = xStep * Double(max(rowCount - 1, 0))
            let x = width * 0.5 - rowWidth / 2.0 + xStep * Double(column)
            let y = gridCenterY - gridHeight / 2.0 + yStep * Double(row)
            slots.append(ProviderLogoSlot(centerX: x, centerY: y, scale: scale))
        }
        return slots
    }

    func resolvedProviderLogoRGBA(for p: Particle, at index: Int) -> RGBA? {
        guard let role = p.role, let provider = p.logoProvider else { return nil }

        let color = p.resolvedLogoColor ?? Self.colorForProvider(
            provider,
            under: colorPalette,
            role: role,
            toneSeed: Self.flameToneSeed(for: p, at: index),
            colorScheme: renderScheme,
            sourceLogoColor: p.logoColor
        )
        let opacity = Self.logoOpacity(for: p, role: role, colorScheme: renderScheme)
        return RGBA(r: color.r, g: color.g, b: color.b, a: opacity)
    }

    static func logoOpacity(for p: Particle, role: String, colorScheme: ColorScheme) -> Double {
        let raw = p.opacity.clamped(to: 0...1)
        let base = colorScheme == .dark ? raw : min(1.0, raw + 0.08)
        let multiplier: Double
        switch role {
        case "logo-flame-inner": multiplier = 1.62
        case "logo-flame-outer": multiplier = 1.44
        case "logo-flame-spark": multiplier = 1.72
        default: multiplier = 1.36
        }
        return min(1.0, base * multiplier)
    }

    static func colorForProvider(
        _ provider: AgentProvider,
        under palette: SwarmColorPalette,
        role: String?,
        toneSeed: Double,
        colorScheme: ColorScheme,
        sourceLogoColor: RGBA? = nil
    ) -> RGBA {
        if let sourceLogoColor {
            return contrastAdjustedSourceLogoColor(sourceLogoColor, colorScheme: colorScheme)
        }

        let base = paletteAwareProviderLogoBase(for: provider, under: palette, role: role, toneSeed: toneSeed)

        if let r = role {
            let seed = (toneSeed - floor(toneSeed)).clamped(to: 0...1)
            let hot = base.lightened(by: r == "logo-flame-inner" ? 0.24 : 0.10)
            let shadow = base.darkened(by: r == "logo-flame-outer" ? 0.30 : 0.15)
            return contrastAdjustedForScheme(shadow.mix(with: hot, amount: seed), colorScheme: colorScheme)
        }
        return contrastAdjustedForScheme(base, colorScheme: colorScheme)
    }

    static func providerLogoColorForTesting(
        _ provider: AgentProvider,
        under palette: SwarmColorPalette,
        role: String?,
        toneSeed: Double,
        colorScheme: ColorScheme,
        sourceLogoColor: RGBA? = nil
    ) -> RGBA {
        colorForProvider(
            provider,
            under: palette,
            role: role,
            toneSeed: toneSeed,
            colorScheme: colorScheme,
            sourceLogoColor: sourceLogoColor
        )
    }

    struct ParticleMetadataForTesting {
        let role: String?
        let logoProvider: AgentProvider?
        let resolvedLogoColor: RGBA?
        let toneSeed: Double?
    }
    func particleMetadataForTesting() -> [ParticleMetadataForTesting] {
        particles.map {
            ParticleMetadataForTesting(
                role: $0.role,
                logoProvider: $0.logoProvider,
                resolvedLogoColor: $0.resolvedLogoColor,
                toneSeed: $0.toneSeed
            )
        }
    }

    static func paletteAwareProviderLogoBase(
        for provider: AgentProvider,
        under palette: SwarmColorPalette,
        role: String?,
        toneSeed: Double
    ) -> RGBA {
        let brand: RGBA = provider == .xAI
            ? RGBA(r: 0.95, g: 0.95, b: 0.98)
            : DesignSystemColors.providerRGBA(for: provider)
        guard palette != .defaultEmber else { return brand }

        let paletteColor = logoPaletteColor(for: palette, role: role, toneSeed: toneSeed)
        let amount: Double = (provider == .factory || provider == .hermes) ? 0.84 : 0.58
        return brand.mix(with: paletteColor, amount: amount)
    }

    static func logoPaletteColor(
        for palette: SwarmColorPalette,
        role: String?,
        toneSeed: Double
    ) -> RGBA {
        let choices: [RGBA]
        switch palette {
        case .defaultEmber:
            choices = [
                RGBA(r: 1.00, g: 0.78, b: 0.15),
                RGBA(r: 0.96, g: 0.36, b: 0.04),
                RGBA(r: 1.00, g: 0.92, b: 0.50)
            ]
        case .auroraTeal:
            choices = [
                RGBA(r: 0.00, g: 0.98, b: 0.88),
                RGBA(r: 0.18, g: 0.72, b: 1.00),
                RGBA(r: 0.72, g: 0.48, b: 1.00)
            ]
        case .sunsetCrimson:
            choices = [
                RGBA(r: 1.00, g: 0.50, b: 0.28),
                RGBA(r: 1.00, g: 0.16, b: 0.50),
                RGBA(r: 0.72, g: 0.22, b: 1.00)
            ]
        case .cyberpunkViolet:
            choices = [
                RGBA(r: 0.10, g: 0.92, b: 1.00),
                RGBA(r: 1.00, g: 0.16, b: 0.96),
                RGBA(r: 0.72, g: 0.32, b: 1.00)
            ]
        case .forestMoss:
            choices = [
                RGBA(r: 0.68, g: 0.88, b: 0.46),
                RGBA(r: 0.32, g: 0.74, b: 0.44),
                RGBA(r: 0.96, g: 0.72, b: 0.24)
            ]
        case .solarFlare:
            choices = [
                RGBA(r: 1.00, g: 0.95, b: 0.66),
                RGBA(r: 1.00, g: 0.58, b: 0.10),
                RGBA(r: 1.00, g: 0.20, b: 0.04)
            ]
        }

        let shiftedSeed: Double
        switch role {
        case "logo-flame-outer": shiftedSeed = toneSeed + 0.18
        case "logo-flame-spark": shiftedSeed = toneSeed + 0.58
        default: shiftedSeed = toneSeed
        }
        let normalized = shiftedSeed - floor(shiftedSeed)
        let scaled = normalized * Double(choices.count)
        let index = min(choices.count - 1, Int(scaled))
        let nextIndex = (index + 1) % choices.count
        let local = scaled - Double(index)
        return choices[index].mix(with: choices[nextIndex], amount: local)
    }

    static func contrastAdjustedSourceLogoColor(_ color: RGBA, colorScheme: ColorScheme) -> RGBA {
        contrastAdjustedForScheme(color, colorScheme: colorScheme)
    }

    static func contrastAdjustedForScheme(_ color: RGBA, colorScheme: ColorScheme) -> RGBA {
        let luminance = relativeLuminance(color)
        if colorScheme == .light, luminance > 0.74 {
            return color.darkened(by: 0.42)
        }
        if colorScheme == .dark, luminance < 0.08 {
            return RGBA(r: 0.84, g: 0.86, b: 0.90, a: color.a)
        }
        if colorScheme == .dark, luminance < 0.22 {
            return color.lightened(by: 0.46)
        }
        return color
    }

    static func relativeLuminance(_ color: RGBA) -> Double {
        0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
    }
}
