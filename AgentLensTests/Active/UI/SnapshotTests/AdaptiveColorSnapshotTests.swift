import XCTest
import SwiftUI
import SnapshotTesting
@testable import OpenBurnBar

// MARK: - Adaptive Color Visual Regression Tests

/// Verifies DesignSystem adaptive colors render correctly in dark and light modes.
@MainActor
final class AdaptiveColorSnapshotTests: XCTestCase {

    func test_designSystemColorSwatches() {
        let view = ColorSwatchGrid()
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 500, height: 600),
            named: SnapshotName.colorSwatches
        )
    }

    func test_providerPrimaryColors() {
        let view = ProviderColorGrid()
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 500, height: 800),
            named: SnapshotName.providerColors
        )
    }
}

// MARK: - Color Swatch Grid

private struct ColorSwatchGrid: View {
    private let tokens: [(String, Color)] = [
        ("background", DesignSystem.Colors.background),
        ("surface", DesignSystem.Colors.surface),
        ("surfaceElevated", DesignSystem.Colors.surfaceElevated),
        ("border", DesignSystem.Colors.border),
        ("borderSubtle", DesignSystem.Colors.borderSubtle),
        ("textPrimary", DesignSystem.Colors.textPrimary),
        ("textSecondary", DesignSystem.Colors.textSecondary),
        ("textMuted", DesignSystem.Colors.textMuted),
        ("success", DesignSystem.Colors.success),
        ("warning", DesignSystem.Colors.warning),
        ("error", DesignSystem.Colors.error),
        ("ember", DesignSystem.Colors.ember),
        ("amber", DesignSystem.Colors.amber),
        ("blaze", DesignSystem.Colors.blaze),
        ("whimsy", DesignSystem.Colors.whimsy),
        ("hermesMercury", DesignSystem.Colors.hermesMercury),
        ("hermesAureate", DesignSystem.Colors.hermesAureate),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                ForEach(tokens, id: \.0) { name, color in
                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(color)
                            .frame(height: 40)
                            .overlay(
                                Rectangle()
                                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                            )
                        Text(name)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background)
    }
}

// MARK: - Provider Color Grid

private struct ProviderColorGrid: View {
    private let providers = AgentProvider.allCases

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                ForEach(providers, id: \.self) { provider in
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Rectangle()
                                .fill(DesignSystem.Colors.primary(for: provider))
                                .frame(height: 30)
                            Rectangle()
                                .fill(DesignSystem.Colors.accent(for: provider))
                                .frame(height: 30)
                        }
                        .overlay(
                            Rectangle()
                            .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                        )
                        Text(provider.displayName)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background)
    }
}
