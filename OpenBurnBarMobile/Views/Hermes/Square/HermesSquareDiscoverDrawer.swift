import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Square Discover Drawer (Hermes Square §3 / §6.2)
//
// Surfaces the Discover panel: recent agents, available capability cards,
// the marketplace placeholder, and brand-zone shortcuts. Phase A
// scaffolding — Phase C wires the marketplace install flow.

struct HermesSquareDiscoverDrawer: View {
    let registry: AgentIdentityRegistry
    let pinnedGrid: PinnedAgentGridConfig
    let onPin: (String) -> Void
    let onUnpin: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .recent

    enum Section: String, CaseIterable, Identifiable {
        case recent
        case capabilities
        case marketplace
        case brandZones
        var id: String { rawValue }
        var displayLabel: String {
            switch self {
            case .recent:        return "Recent"
            case .capabilities:  return "Capabilities"
            case .marketplace:   return "Marketplace"
            case .brandZones:    return "Agents"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("", selection: $section) {
                    ForEach(Section.allCases) { sec in
                        Text(sec.displayLabel).tag(sec)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 14)

                Divider()

                ScrollView {
                    switch section {
                    case .recent:        recentSection
                    case .capabilities:  capabilitiesSection
                    case .marketplace:   marketplaceSection
                    case .brandZones:    brandZoneSection
                    }
                }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Sections

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(registry.identities, id: \.id) { identity in
                row(for: identity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // For Phase A: list capabilities aggregated across all agents.
            let allCapabilities: [AgentCapabilities] = [
                .toolUse, .vision, .audio, .agentLoops, .fileEdits,
                .shell, .webBrowse, .codeExecution, .imageGen, .memory,
                .streamingDiff, .mcpUI
            ]
            ForEach(allCapabilities, id: \.rawValue) { cap in
                let pillName = cap.displayPills.first ?? "Capability"
                let owners = registry.identities.filter { $0.capabilities.contains(cap) }
                HStack {
                    Text(pillName)
                        .font(.callout.bold())
                        .foregroundStyle(DesignSystemColors.textPrimary)
                    Spacer()
                    Text("\(owners.count) agents")
                        .font(.caption)
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DesignSystemColors.surface.opacity(0.5))
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var marketplaceSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(DesignSystemColors.ember)
            Text("Marketplace")
                .font(.headline)
                .foregroundStyle(DesignSystemColors.textPrimary)
            Text("Install third-party agents from a manifest URL or QR code. Coming in Phase C — first-party only at GA.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignSystemColors.textSecondary)
                .padding(.horizontal, 24)
        }
        .padding(.top, 40)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
    }

    private var brandZoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(registry.identities, id: \.id) { identity in
                row(for: identity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(for identity: AgentIdentity) -> some View {
        let pinned = pinnedGrid.pinnedURIs.contains(identity.id)
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(hex: identity.paletteHex)).frame(width: 30, height: 30)
                Text(identity.glyph).font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.displayName).font(.callout.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
                if let tagline = identity.tagline {
                    Text(tagline)
                        .font(.caption)
                        .foregroundStyle(DesignSystemColors.textMuted)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                if pinned { onUnpin(identity.id) } else { onPin(identity.id) }
                HapticBus.tabChange()
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? DesignSystemColors.ember : DesignSystemColors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignSystemColors.surface.opacity(0.5))
        )
    }
}
