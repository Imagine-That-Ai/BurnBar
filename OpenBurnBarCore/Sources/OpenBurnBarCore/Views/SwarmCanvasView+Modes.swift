import SwiftUI
import Foundation
import CoreGraphics
import CoreText
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// Swarm formation mode transitions + shape-settle timing.
// Extracted from SwarmCanvasView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension SwarmSimulation {

    public func assignMode(_ next: SwarmFormationMode, at assignedAt: TimeInterval = Date.timeIntervalSinceReferenceDate, uiMode: UIMode = .standard) {
        mode = next
        modeAssignedAt = assignedAt
        shapeSettledAt = nil
        let shapePoints: [SIMD2<Double>]
        let shapeRoles: [String?]
        let progress: [Double]
        switch next {
        case .swarm:
            for i in particles.indices {
                clearFormationMetadata(at: i)
            }
            return
        case .shapeProviderLogo(let providers):
            let specs = providers.map { provider in (provider: provider, points: providerLogoPoints(for: provider)) }
            assignProviderLogoFormation(specs)
            return
        case .shapeDollar:
            shapePoints = dollarPoints.map { SIMD2(Double($0.x), Double($0.y)) }
            shapeRoles = Array(repeating: nil, count: shapePoints.count)
            progress = (0..<shapePoints.count).map { _ in Double.random(in: 0...1) }
        case .shapeCode:
            shapePoints = codePoints.map { SIMD2(Double($0.x), Double($0.y)) }
            shapeRoles = Array(repeating: nil, count: shapePoints.count)
            progress = (0..<shapePoints.count).map { _ in Double.random(in: 0...1) }
        case .shapeBurnBarLogo:
            shapePoints = burnBarLogoPoints.map { SIMD2(Double($0.point.x), Double($0.point.y)) }
            shapeRoles = burnBarLogoPoints.map { $0.role }
            progress = burnBarLogoPoints.map { $0.progress }
        case .shapeGrok:
            assignProviderLogoFormation([(provider: .xAI, points: Self.grokLogoPoints)])
            return
        case .shapeRings:
            shapePoints = ringPoints.map { SIMD2(Double($0.point.x), Double($0.point.y)) }
            shapeRoles = Array(repeating: nil, count: shapePoints.count)
            progress = (0..<shapePoints.count).map { _ in Double.random(in: 0...1) }
        case .shapeRouterFlow:
            shapePoints = routerFlowPoints.map { SIMD2(Double($0.point.x), Double($0.point.y)) }
            shapeRoles = routerFlowPoints.map { $0.role }
            progress = routerFlowPoints.map { $0.progress }
        case .shapeSkillet:
            shapePoints = skilletPoints.map { SIMD2(Double($0.point.x), Double($0.point.y)) }
            shapeRoles = skilletPoints.map { $0.role }
            progress = skilletPoints.map { $0.progress }
        case .shapeApple:
            shapePoints = applePoints.map { SIMD2(Double($0.point.x), Double($0.point.y)) }
            shapeRoles = applePoints.map { $0.role }
            progress = applePoints.map { $0.progress }
        case .shapeChefHat:
            shapePoints = chefHatPoints.map { SIMD2(Double($0.point.x), Double($0.point.y)) }
            shapeRoles = chefHatPoints.map { $0.role }
            progress = chefHatPoints.map { $0.progress }
        case .shapeChili:
            shapePoints = chiliPoints.map { SIMD2(Double($0.point.x), Double($0.point.y)) }
            shapeRoles = chiliPoints.map { $0.role }
            progress = chiliPoints.map { $0.progress }
        }

        let width = Double(bounds.width)
        let height = Double(bounds.height)
        var centerX = width * 0.5
        var centerY = height * 0.45
        var scaleFactor = 0.35

        if width > 960 {
            // Wide layouts (Mac / iPad): keep shapes off to the side and high,
            // away from the central content columns.
            switch next {
            case .shapeRings:
                centerX = width * 0.78
                centerY = height * 0.30
                scaleFactor = 0.38
            case .shapeBurnBarLogo:
                centerX = width * 0.75
                centerY = height * 0.32
                scaleFactor = 0.30
            case .shapeRouterFlow:
                centerX = width * 0.5
                centerY = height * 0.26
                scaleFactor = 0.6
            default:
                centerX = width * 0.74
                centerY = height * 0.28
                scaleFactor = 0.32
            }
        } else {
            // Phones: cards fill the middle, so present shapes in the emptier
            // upper band beneath the nav bar where they're clearly visible.
            switch next {
            case .shapeRings:
                centerY = height * 0.24
                scaleFactor = 0.34
            case .shapeBurnBarLogo:
                centerY = height * 0.24
                scaleFactor = 0.30
            case .shapeRouterFlow:
                centerX = width * 0.5
                centerY = height * 0.24
                scaleFactor = 0.62
            default:
                centerY = height * 0.22
                scaleFactor = 0.32
            }
        }
        let scale = min(width, height) * scaleFactor

        // Shuffle particle order so assigned points are evenly distributed.
        var indices = Array(particles.indices)
        indices.shuffle()
        for (slot, particleIdx) in indices.enumerated() {
            if slot < shapePoints.count {
                let pt = shapePoints[slot]
                particles[particleIdx].tx = centerX + pt.x * scale
                particles[particleIdx].ty = centerY + pt.y * scale
                particles[particleIdx].slotIndex = 0
                applyFormationMetadata(
                    at: particleIdx,
                    role: shapeRoles[slot],
                    flowProgress: progress[slot]
                )
            } else {
                clearFormationMetadata(at: particleIdx)
            }
        }
    }

    func providerLogoPoints(for provider: AgentProvider) -> [ShapePoint] {
        if provider == .xAI {
            return Self.xAILogoPoints
        }
        if let cached = Self.providerLogoPointCache[provider] {
            return cached
        }
        let points = SwarmSimulation.logoPoints(
            for: provider,
            fallback: SwarmSimulation.fallbackLogoPoints(for: provider)
        )
        Self.providerLogoPointCache[provider] = points
        return points
    }

    func assignProviderLogoFormation(_ specs: [(provider: AgentProvider, points: [ShapePoint])]) {
        let visibleSpecs = specs.filter { !$0.points.isEmpty }
        let count = visibleSpecs.count
        guard count > 0 else {
            for i in particles.indices {
                clearFormationMetadata(at: i)
            }
            return
        }

        var groups: [[Int]] = Array(repeating: [], count: count)
        var indices = Array(particles.indices)
        indices.shuffle()
        for (slot, idx) in indices.enumerated() {
            groups[slot % count].append(idx)
        }

        let width = Double(bounds.width)
        let height = Double(bounds.height)
        let slots = Self.providerLogoSlots(count: count, width: width, height: height)

        for specIndex in 0..<count {
            let spec = visibleSpecs[specIndex]
            let logoSlot = slots[specIndex]
            let groupParticles = groups[specIndex]
            for (slot, particleIdx) in groupParticles.enumerated() {
                let pointIndex: Int
                if groupParticles.count <= spec.points.count {
                    let t = Double(slot) / Double(max(groupParticles.count - 1, 1))
                    pointIndex = min(spec.points.count - 1, Int((Double(spec.points.count - 1) * t).rounded()))
                } else {
                    pointIndex = slot % spec.points.count
                }
                let pt = spec.points[pointIndex]
                particles[particleIdx].tx = logoSlot.centerX + Double(pt.point.x) * logoSlot.scale
                particles[particleIdx].ty = logoSlot.centerY + Double(pt.point.y) * logoSlot.scale
                particles[particleIdx].isGlyph = false
                particles[particleIdx].slotIndex = specIndex
                applyFormationMetadata(
                    at: particleIdx,
                    role: pt.role ?? "logo-flame-inner",
                    logoProvider: spec.provider,
                    logoColor: pt.logoColor,
                    flowProgress: pt.progress
                )
            }
        }
    }

    func clearFormationMetadata(at index: Int) {
        particles[index].tx = nil
        particles[index].ty = nil
        particles[index].role = nil
        particles[index].logoProvider = nil
        particles[index].logoColor = nil
        particles[index].resolvedLogoColor = nil
        particles[index].toneSeed = nil
        particles[index].slotIndex = nil
    }

    func applyFormationMetadata(
        at index: Int,
        role: String?,
        logoProvider: AgentProvider? = nil,
        logoColor: RGBA? = nil,
        flowProgress: Double
    ) {
        particles[index].role = role
        particles[index].logoProvider = logoProvider
        particles[index].logoColor = logoColor
        particles[index].flowProgress = flowProgress
        particles[index].toneSeed = nil
        particles[index].toneSeed = Self.flameToneSeed(for: particles[index], at: index)

        if logoProvider != nil {
            refreshResolvedLogoColor(at: index, scheme: renderScheme)
        } else {
            particles[index].resolvedLogoColor = nil
        }
    }

    var effectiveShapeSettleFallbackDelay: TimeInterval {
        Self.shapeSettleFallbackDelay / motionSpeedMultiplier.clamped(to: 0.35...2.5)
    }

    func shouldDelayCycleForAdmireHold(now: TimeInterval) -> Bool {
        guard mode.requiresSettledAdmireHold else { return false }

        if shapeSettledAt == nil {
            if currentShapeIsSettled()
                || now - modeAssignedAt >= effectiveCycleInterval + effectiveShapeSettleFallbackDelay {
                shapeSettledAt = now
            } else {
                return true
            }
        }

        guard let settledAt = shapeSettledAt else { return true }
        return now < settledAt + Self.shapeAdmireHoldDuration
    }

    func currentShapeIsSettled() -> Bool {
        // Tighten the threshold at slower speeds so particles must form a sharper,
        // fully-settled shape before starting the hold/admire timer.
        let baseThreshold = max(22.0, Double(min(bounds.width, bounds.height)) * 0.022)
        let threshold = baseThreshold * motionSpeedMultiplier.clamped(to: 0.5...1.0)

        var targeted = 0
        var close = 0
        var totalDistance = 0.0

        for particle in particles {
            guard let tx = particle.tx, let ty = particle.ty else { continue }
            targeted += 1
            let distance = hypot(tx - particle.x, ty - particle.y)
            totalDistance += distance
            if distance <= threshold {
                close += 1
            }
        }

        guard targeted > 0 else { return true }
        let closeFraction = Double(close) / Double(targeted)
        let averageDistance = totalDistance / Double(targeted)
        return closeFraction >= Self.shapeSettledParticleFraction
            && averageDistance <= threshold * 1.75
    }
}
