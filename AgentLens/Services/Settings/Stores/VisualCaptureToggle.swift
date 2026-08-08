import SwiftUI
import OpenBurnBarCore

// MARK: - Visual Capture Source Toggle

/// Capsule segmented control for choosing the visual surface BurnBar shares:
/// CLI terminal (PTY, always available) vs Desktop app window (when installed).
///
/// Gated by the injected `settingsManager.visualCaptureSourceToggleEnabled`.
/// Ineligible providers (CLI-only or plugin-only) show a `CLI only` badge instead.
@MainActor
struct VisualCaptureToggle: View {
    let provider: AgentProvider
    @Bindable var settingsManager: SettingsManager

    init(provider: AgentProvider, settingsManager: SettingsManager) {
        self.provider = provider
        self.settingsManager = settingsManager
    }

    private var isEligible: Bool {
        settingsManager.isToggleEligible(provider)
    }

    private var selectedSource: VisualCaptureSource {
        settingsManager.visualCaptureSource(for: provider)
    }

    private var isDesktopInstalled: Bool {
        VisualCaptureBundleChecker.isDesktopInstalled(for: provider)
    }

    var body: some View {
        Group {
            if !settingsManager.visualCaptureSourceToggleEnabled {
                EmptyView()
            } else if !isEligible {
                cliOnlyBadge
            } else {
                toggleControl
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Badge for CLI-only / plugin-only providers

    private var cliOnlyBadge: some View {
        Text("CLI only")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
            )
            .overlay(
                Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            )
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("CLI only")
            .accessibilityHint("This provider has no desktop app — only the terminal can be shared")
            .help("This provider has no desktop app — only the terminal can be shared")
    }

    // MARK: - Segmented toggle for Both providers

    private var toggleControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                segmentButton(title: "CLI Terminal", source: .cliPTY)
                segmentButton(title: "Desktop App", source: .desktopApp)
            }
            .padding(2)
            .background(
                Capsule().fill(DesignSystem.Colors.surface.opacity(0.6))
            )
            .overlay(
                Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            )
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Visual surface for \(provider.displayName)")
            .accessibilityHint("Shares terminal or desktop window when you start screen share")

            if !isDesktopInstalled {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Text("Desktop app not installed — using terminal")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .accessibilityLabel("Desktop app not installed — using terminal")
                .help("Install the desktop app, or keep using CLI Terminal. See docs/PROVIDERS.md for download links.")
            }
        }
    }

    private func segmentButton(title: String, source: VisualCaptureSource) -> some View {
        let isSelected = selectedSource == source
        let isDesktopAndMissing = source == .desktopApp && !isDesktopInstalled

        return Button {
            guard !isDesktopAndMissing else { return }
            if selectedSource != source {
                withAnimation(.easeInOut(duration: 0.18)) {
                    settingsManager.setVisualCaptureSource(source, for: provider)
                }
            }
        } label: {
            Text(title)
                .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .rounded))
                .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.white.opacity(0.95) : Color.clear)
                        .shadow(color: isSelected ? Color.black.opacity(0.08) : .clear, radius: 3, x: 0, y: 1)
                )
                .opacity(isDesktopAndMissing ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDesktopAndMissing)
        .frame(minHeight: 28)
        .contentShape(Capsule())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isDesktopAndMissing ? "Desktop app not installed" : "")
        .help(isDesktopAndMissing ? "Desktop app not installed — using terminal. See docs/PROVIDERS.md" : "")
    }
}

// MARK: - Inline pill for ScreenShareViewer header

@MainActor
struct VisualCaptureInlinePill: View {
    let provider: AgentProvider
    @Bindable var settingsManager: SettingsManager
    var isCompact: Bool = true

    private var selectedSource: VisualCaptureSource {
        settingsManager.visualCaptureSource(for: provider)
    }

    var body: some View {
        if !settingsManager.visualCaptureSourceToggleEnabled || !settingsManager.isToggleEligible(provider) {
            EmptyView()
        } else {
            HStack(spacing: 2) {
                inlineSegment(title: isCompact ? "CLI" : "CLI Terminal", source: .cliPTY)
                inlineSegment(title: isCompact ? "Desktop" : "Desktop App", source: .desktopApp)
            }
            .padding(2)
            .background(Capsule().fill(DesignSystem.Colors.surface.opacity(0.6)))
            .overlay(Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5))
            .accessibilityLabel("Visual surface for \(provider.displayName)")
        }
    }

    private func inlineSegment(title: String, source: VisualCaptureSource) -> some View {
        let isSelected = selectedSource == source
        let isDesktopAndMissing = source == .desktopApp && !VisualCaptureBundleChecker.isDesktopInstalled(for: provider)
        return Button {
            guard !isDesktopAndMissing else { return }
            if selectedSource != source {
                settingsManager.setVisualCaptureSource(source, for: provider)
            }
        } label: {
            Text(title)
                .font(.system(size: 9, weight: isSelected ? .semibold : .medium, design: .rounded))
                .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(isSelected ? Color.white.opacity(0.95) : Color.clear))
                .opacity(isDesktopAndMissing ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDesktopAndMissing)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Bundle checker (shared with engine)

enum VisualCaptureBundleChecker {
    static func isDesktopInstalled(for provider: AgentProvider) -> Bool {
        // TUI / always-available surfaces
        if provider == .hermes || provider == .openCode { return true }
        let ids = desktopBundleIdentifiers(for: provider)
        if ids.isEmpty { return false }
        // Check via NSWorkspace first, then fallback to /Applications path
        for bundleID in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
               FileManager.default.fileExists(atPath: url.path) {
                return true
            }
        }
        for path in desktopAppPaths(for: provider)
            where FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) {
            return true
        }
        return false
    }

    static func desktopBundleIdentifiers(for provider: AgentProvider) -> [String] {
        switch provider {
        case .claudeCode: return ["com.anthropic.claudefordesktop", "com.anthropic.claude-code"]
        case .codex: return ["com.openai.chat", "com.openai.codex-desktop"]
        case .cursor, .cursorAgent: return ["com.todesktop.230313mzl4w4u92", "com.todesktop.230313mzl4w4u92.Cursor"]
        case .factory: return ["com.factory.app", "com.factory.desktop"]
        case .minimax: return ["com.minimax.app", "com.minimax.desktop", "com.minimax.agent"]
        case .zai: return ["ai.zcode.app", "com.zai.desktop", "com.zcode.app"]
        case .devin: return ["com.devin.app", "com.devin.desktop"]
        case .warp: return ["com.warp.Warp"]
        case .ollama: return ["com.ollama.ollama", "com.openai.ollama"]
        case .hermes: return ["com.hermes.app"] // TUI is always true, but keep for completeness
        case .openCode: return ["com.openblock.opencode"]
        default: return []
        }
    }

    static func desktopAppPaths(for provider: AgentProvider) -> [String] {
        switch provider {
        case .claudeCode: return ["/Applications/Claude.app", "/Applications/Claude Code.app"]
        case .codex: return ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
        case .cursor, .cursorAgent: return ["/Applications/Cursor.app"]
        case .factory: return ["/Applications/Factory.app", "/Applications/Factory Desktop.app"]
        case .minimax: return ["/Applications/MiniMax.app", "/Applications/MiniMax Agent.app"]
        case .zai: return ["/Applications/ZCode.app", "/Applications/Z.ai.app"]
        case .devin: return ["/Applications/Devin.app"]
        case .warp: return ["/Applications/Warp.app"]
        case .ollama: return ["/Applications/Ollama.app"]
        case .openCode: return ["/Applications/OpenCode.app"]
        case .hermes: return []
        default: return []
        }
    }
}

// MARK: - ScreenShareViewer helpers

struct ScreenShareViewerInlineHeader: View {
    let provider: AgentProvider
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        HStack {
            Label("Screen Share", systemImage: "rectangle.on.rectangle")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            VisualCaptureInlinePill(provider: provider, settingsManager: settingsManager)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ScreenSharePreviewPlaceholder: View {
    let provider: AgentProvider
    @Bindable var settingsManager: SettingsManager

    private var isDesktop: Bool {
        settingsManager.visualCaptureSource(for: provider) == .desktopApp
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: isDesktop ? "macwindow" : "terminal")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(isDesktop ? "Desktop window preview" : "PTY terminal preview")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text(isDesktop ? "Window thumbnail when sharing starts" : "Live transcript snippet")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            )
            .frame(height: 120)
            .accessibilityLabel(isDesktop ? "Desktop window preview" : "PTY terminal preview")
    }
}
