import SwiftUI
import OpenBurnBarComputerUseCore

struct ChatPanelHeader: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    var onNewChat: () -> Void
    var onMinimize: () -> Void
    var onClose: () -> Void
    var onShowClearChatPrompt: () -> Void
    var onMaximize: (() -> Void)? = nil
    var onPopOut: (() -> Void)? = nil
    @State private var showChatMenu = false
    @State private var headerDragStart: CGSize?
    var containerSize: CGSize
    var edgePadding: CGFloat

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 20)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .help("Drag to move")
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            if headerDragStart == nil { headerDragStart = controller.panelFloatOffset }
                            let start = headerDragStart ?? .zero
                            controller.applyClampedPanelDrag(start: start, translation: g.translation, container: containerSize, padding: edgePadding)
                        }
                        .onEnded { _ in
                            headerDragStart = nil
                            controller.persistPanelGeometry()
                        }
                )

            VStack(spacing: 4) {
                ChatEngineBackendStrip(controller: controller, settingsManager: settingsManager)
                HermesModelStrip(controller: controller, settingsManager: settingsManager)
            }
            ChatEngineModelMenu(controller: controller)

            Button {
                controller.revealChatWorkspaceInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(headerIconTint)
            }
            .buttonStyle(.plain)
            .help("Show this chat's workspace in Finder")

            ChatDesktopControlButton(controller: controller, tint: headerIconTint)

            Spacer(minLength: 0)

            Button {
                onNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(headerIconTint)
            }
            .buttonStyle(.plain)
            .help("New chat")

            Button {
                showChatMenu.toggle()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Chat options")
            .popover(isPresented: $showChatMenu, arrowEdge: .top) {
                ChatMenuPopover(controller: controller, onShowClearChatPrompt: onShowClearChatPrompt)
            }

            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(headerIconTint)
                }
                .buttonStyle(.plain)
                .help("Pop out chat into its own window")
            }

            if let onMaximize {
                Button(action: onMaximize) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right.square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(headerIconTint)
                }
                .buttonStyle(.plain)
                .help("Maximize chat into the dashboard workspace")
            }

            Button {
                onMinimize()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Minimize to pill")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Helpers

    private var headerIconTint: Color {
        switch controller.chatBackend {
        case .hermes:   return DesignSystem.Colors.hermesAureate
        case .piAgent:  return DesignSystem.Colors.whimsy
        default:        return DesignSystem.Colors.whimsy
        }
    }
}

struct ChatDesktopControlButton: View {
    @Bindable var controller: ChatSessionController
    var tint: Color

    @State private var showsPopover = false
    @State private var selectedCapabilities: Set<AgentDesktopCapability> = AgentPermissionPreset.workspace.capabilities
    @State private var selectedTrustMode: ComputerUseTrustMode = .manual

    var body: some View {
        Button {
            syncFromGrant()
            showsPopover.toggle()
        } label: {
            Image(systemName: controller.desktopControlEnabled ? "hand.raised.fill" : "hand.raised")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(controller.desktopControlEnabled ? DesignSystem.Colors.success : tint)
        }
        .buttonStyle(.plain)
        .help(controller.desktopControlEnabled ? "Agent desktop permission is on" : "Agent desktop permission")
        .accessibilityLabel("Agent permissions")
        .accessibilityValue(controller.desktopControlEnabled ? "On" : "Off")
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            permissionPopover
        }
        .onChange(of: controller.chatBackend) { _, _ in
            syncFromGrant()
        }
        .onChange(of: controller.desktopControlEnabled) { _, _ in
            syncFromGrant()
        }
    }

    private var permissionPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(controller.desktopControlEnabled ? DesignSystem.Colors.success : tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Permissions")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(statusText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                Text(activePresetTitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(controller.desktopControlEnabled ? DesignSystem.Colors.success : DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DesignSystem.Colors.surfaceElevated, in: Capsule())
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(AgentPermissionPreset.allCases) { preset in
                    presetButton(preset)
                }
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    permissionToggle(.desktopBrowser, icon: "safari")
                    permissionToggle(.desktopScreenshot, icon: "camera.viewfinder")
                    permissionToggle(.accessibilityInspect, icon: "viewfinder")
                    permissionToggle(.desktopSystemInput, icon: "cursorarrow.click")
                    permissionToggle(.desktopFileExport, icon: "desktopcomputer")
                    permissionToggle(.workspaceRead, icon: "doc.text.magnifyingglass")
                    permissionToggle(.workspaceWrite, icon: "square.and.pencil")
                    permissionToggle(.shell, icon: "terminal")
                    permissionToggle(.shellUnrestricted, icon: "exclamationmark.terminal")
                }
                .padding(.top, 8)
            } label: {
                Text("Fine tune")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            if let riskText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 12, weight: .semibold))
                    Text(riskText)
                        .font(DesignSystem.Typography.tiny)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DesignSystem.Colors.warning)
                .padding(10)
                .background(DesignSystem.Colors.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            Picker("Trust", selection: $selectedTrustMode) {
                ForEach(ComputerUseTrustMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(selectedCapabilities.isEmpty)

            HStack(spacing: 10) {
                if controller.desktopControlEnabled {
                    Button(role: .destructive) {
                        controller.revokeDesktopControl()
                        showsPopover = false
                    } label: {
                        Label("Revoke", systemImage: "xmark.shield")
                    }
                }

                Spacer(minLength: 0)

                Button {
                    applySelection()
                } label: {
                    Label(primaryActionTitle, systemImage: selectedCapabilities.isEmpty ? "xmark.shield" : "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 390)
        .background(DesignSystem.Colors.surface)
        .onAppear(perform: syncFromGrant)
    }

    private var statusText: String {
        guard let grant = controller.activeDesktopControlGrant else {
            return "\(controller.chatBackend.rawValue) has no tools yet"
        }
        let minutes = max(1, Int(ceil(grant.expiresAt.timeIntervalSinceNow / 60)))
        return "\(grant.runtimeID.displayName) · \(minutes)m left"
    }

    private var activePresetTitle: String {
        matchingPreset?.title ?? "Custom"
    }

    private var matchingPreset: AgentPermissionPreset? {
        AgentPermissionPreset.allCases.first { $0.matches(capabilities: selectedCapabilities, trustMode: selectedTrustMode) }
    }

    private var primaryActionTitle: String {
        selectedCapabilities.isEmpty ? "Turn Off" : (controller.desktopControlEnabled ? "Update" : "Allow")
    }

    private var riskText: String? {
        if matchingPreset == .yolo {
            return "YOLO grants every capability in Trusted mode, including unrestricted shell. High-risk Mac actions still pass through OpenBurnBar panic controls."
        }
        var warnings: [String] = []
        if selectedTrustMode == .trusted, !selectedCapabilities.isEmpty {
            warnings.append("Trusted mode reduces repeated prompts inside allowed scopes.")
        }
        if selectedCapabilities.contains(.desktopSystemInput) {
            warnings.append("Mac input can click and type in frontmost apps.")
        }
        if selectedCapabilities.contains(.accessibilityInspect) {
            warnings.append("Accessibility inspect can read visible app text.")
        }
        if selectedCapabilities.contains(.shell) {
            warnings.append("Shell writes are workspace-sandboxed, but commands can read local files.")
        }
        if selectedCapabilities.contains(.desktopFileExport) {
            warnings.append("Desktop export can copy workspace files into OpenBurnBar Agent Drops on your Desktop.")
        }
        if selectedCapabilities.contains(.shellUnrestricted) {
            warnings.append("Unrestricted shell can write outside the workspace and should only be used for YOLO sessions.")
        }
        guard !warnings.isEmpty else { return nil }
        return warnings.joined(separator: " ")
    }

    private func presetButton(_ preset: AgentPermissionPreset) -> some View {
        let isSelected = preset.matches(capabilities: selectedCapabilities, trustMode: selectedTrustMode)
        return Button {
            selectedCapabilities = preset.capabilities
            selectedTrustMode = preset.trustMode
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: preset.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(preset.title)
                        .font(DesignSystem.Typography.caption)
                        .lineLimit(1)
                }
                Text(preset.subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? DesignSystem.Colors.ember.opacity(0.16) : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? DesignSystem.Colors.ember.opacity(0.70) : DesignSystem.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func permissionToggle(_ capability: AgentDesktopCapability, icon: String) -> some View {
        Toggle(isOn: binding(for: capability)) {
            Label(capability.displayName, systemImage: icon)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .toggleStyle(.checkbox)
    }

    private func binding(for capability: AgentDesktopCapability) -> Binding<Bool> {
        Binding(
            get: { selectedCapabilities.contains(capability) },
            set: { enabled in
                if enabled {
                    selectedCapabilities.insert(capability)
                } else {
                    selectedCapabilities.remove(capability)
                }
            }
        )
    }

    private func applySelection() {
        if selectedCapabilities.isEmpty {
            controller.revokeDesktopControl()
        } else {
            controller.grantDesktopControl(
                capabilities: selectedCapabilities,
                trustMode: selectedTrustMode
            )
        }
        showsPopover = false
    }

    private func syncFromGrant() {
        if let grant = controller.activeDesktopControlGrant {
            selectedCapabilities = grant.capabilities
            selectedTrustMode = grant.trustMode
        } else {
            selectedCapabilities = AgentPermissionPreset.workspace.capabilities
            selectedTrustMode = AgentPermissionPreset.workspace.trustMode
        }
    }
}
