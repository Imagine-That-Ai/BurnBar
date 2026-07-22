import Foundation
import OpenBurnBarKernel

// remediation(core-swarm-decomp): relocated verbatim from SwarmCanvasView.swift to
// shrink that 3,926-line god-file. Behavior-preserving move only; SwiftPM directory
// auto-discovery picks this sibling up automatically.

// MARK: - Simulation Core

public enum SwarmFormationMode: Equatable {
    case swarm
    case shapeDollar
    case shapeCode
    case shapeBurnBarLogo
    case shapeRings
    case shapeRouterFlow
    case shapeProviderLogo([AgentProvider])
    case shapeGrok
    case shapeSkillet
    case shapeApple
    case shapeChefHat
    case shapeChili

    static let showcaseProviders: [AgentProvider] = AgentProvider.swarmGlyphProviders

    static var providerLogoGroups: [[AgentProvider]] {
        providerLogoGroups(for: showcaseProviders)
    }

    static var defaultCycle: [SwarmFormationMode] {
        defaultCycle(for: showcaseProviders)
    }

    static var inspectionCycle: [SwarmFormationMode] {
        inspectionCycle(for: showcaseProviders)
    }

    static func providerLogoGroups(for providers: [AgentProvider]) -> [[AgentProvider]] {
        grouped(SwarmProviderGlyphSelection.normalized(providers), size: 2)
    }

    static func defaultCycle(for providers: [AgentProvider], excludeBrandShapes: Bool = false, uiMode: UIMode = .standard) -> [SwarmFormationMode] {
        if uiMode == .cooking {
            return [
                .swarm,
                .shapeSkillet,
                .swarm,
                .shapeApple,
                .swarm,
                .shapeChefHat,
                .swarm,
                .shapeChili
            ]
        }

        let enabledProviders = SwarmProviderGlyphSelection.normalized(providers)
        let providerLogoModes = providerLogoGroups(for: enabledProviders).map {
            SwarmFormationMode.shapeProviderLogo($0)
        }
        let grokModes: [SwarmFormationMode] = enabledProviders.contains(.xAI)
            ? [.shapeGrok]
            : []
        if excludeBrandShapes {
            let logoModes = providerLogoModes + grokModes
            guard !logoModes.isEmpty else { return [.swarm] }
            return logoModes.flatMap { mode in
                [
                    mode,
                    SwarmFormationMode.swarm
                ]
            }
        }

        let providerCycle = providerLogoModes.flatMap { mode in
            [
                SwarmFormationMode.swarm,
                mode
            ]
        }
        let grokCycle = grokModes.flatMap { [SwarmFormationMode.swarm, $0] }

        return [
            .swarm,
            .shapeDollar,
            .swarm,
            .shapeCode,
            .swarm,
            .shapeBurnBarLogo
        ] + providerCycle + grokCycle + [
            .swarm,
            .shapeRings,
            .swarm,
            .shapeRouterFlow
        ]
    }

    static func inspectionCycle(for providers: [AgentProvider], excludeBrandShapes: Bool = false, uiMode: UIMode = .standard) -> [SwarmFormationMode] {
        if uiMode == .cooking {
            return [
                .swarm,
                .shapeSkillet,
                .shapeApple,
                .shapeChefHat,
                .shapeChili
            ]
        }

        let enabledProviders = SwarmProviderGlyphSelection.normalized(providers)
        let grokCycle: [SwarmFormationMode] = enabledProviders.contains(.xAI) ? [.shapeGrok] : []

        if excludeBrandShapes {
            return [.swarm] + enabledProviders.map { provider in
                .shapeProviderLogo([provider])
            } + grokCycle + providerLogoGroups(for: enabledProviders).map { group in
                .shapeProviderLogo(group)
            }
        }

        return [
            .swarm,
            .shapeDollar,
            .shapeCode,
            .shapeBurnBarLogo,
            .shapeRings,
            .shapeRouterFlow
        ] + enabledProviders.map { provider in
            .shapeProviderLogo([provider])
        } + grokCycle + providerLogoGroups(for: enabledProviders).map { group in
            .shapeProviderLogo(group)
        }
    }

    var requiresSettledAdmireHold: Bool {
        switch self {
        case .shapeDollar, .shapeCode, .shapeBurnBarLogo, .shapeRings, .shapeProviderLogo, .shapeGrok,
             .shapeSkillet, .shapeApple, .shapeChefHat, .shapeChili:
            return true
        case .swarm, .shapeRouterFlow:
            return false
        }
    }

    private static func grouped(_ providers: [AgentProvider], size: Int) -> [[AgentProvider]] {
        guard size > 0 else { return [] }
        var groups: [[AgentProvider]] = []
        var index = 0
        while index < providers.count {
            groups.append(Array(providers[index..<min(index + size, providers.count)]))
            index += size
        }
        return groups
    }
}
