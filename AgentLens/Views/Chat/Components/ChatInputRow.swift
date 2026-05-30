import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenBurnBarCore

struct ChatInputRow: View {
    @Bindable var controller: ChatSessionController
    var chatBackend: ChatBackendID
    var cliAssistantAllowed: Bool = true
    var onRequestCLIAssistantConsent: (() -> Void)?
    var onSubmit: () -> Void

    @State private var isDropTargeted = false

    private var inputPlaceholder: String {
        switch chatBackend {
        case .codex: return "Ask Codex\u{2026}"
        case .claude: return "Ask Claude Code\u{2026}"
        case .hermes: return "Ask Hermes\u{2026}"
        case .openclaw: return "Ask OpenClaw\u{2026}"
        case .piAgent: return "Ask Pi\u{2026}"
        case .droid: return "Ask Droid\u{2026}"
        case .forge: return "Ask Forge\u{2026}"
        case .antigravity: return "Ask Antigravity\u{2026}"
        case .cursorAgent: return "Ask Cursor Agent\u{2026}"
        }
    }

    private var inputStrokeGradient: LinearGradient {
        chatBackend == .hermes
            ? LinearGradient(colors: [DesignSystem.Colors.hermesMercury.opacity(0.4), DesignSystem.Colors.hermesAureate.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [DesignSystem.Colors.whimsy.opacity(0.3), DesignSystem.Colors.border.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var sendDisabled: Bool {
        controller.isStreaming
            || (controller.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && controller.pendingAttachments.isEmpty)
    }

    private var shouldRequestCLIAssistantPermission: Bool {
        chatBackend.requiresCLIAssistantConsent && !cliAssistantAllowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.lastRetrievalHadNoEvidence, !controller.isStreaming {
                Text("No indexed excerpts matched your last question\u{2014}try \u{201c}Search indexed sessions\u{201d}, enable indexing in Settings, or rephrase.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !controller.pendingAttachments.isEmpty || controller.attachmentError != nil {
                ChatAttachmentTray(
                    attachments: controller.pendingAttachments,
                    isHermes: chatBackend == .hermes,
                    attachmentError: controller.attachmentError,
                    onRemove: { controller.removeAttachment($0) },
                    onReveal: { revealAttachment($0) }
                )
            }
            Group {
                if let preview = controller.pendingTextExpansionPreview {
                    textExpansionPreview(preview)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .animation(DesignSystem.Animation.standard, value: controller.pendingTextExpansionPreview != nil)
            if shouldRequestCLIAssistantPermission {
                cliPermissionPrompt
            }
            HStack(alignment: .bottom, spacing: DesignSystem.Spacing.sm) {
                attachmentMenu
                TextField(inputPlaceholder, text: $controller.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit { submitOrRequestPermission() }
                    .padding(DesignSystem.Spacing.sm)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous).fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.3))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous).strokeBorder(inputStrokeGradient, lineWidth: 0.75))
                    .animation(DesignSystem.Animation.snappy, value: chatBackend)
                    .onChange(of: controller.inputText) { _, _ in
                        controller.handleTextExpansionDraftChange()
                    }
                    .onPasteCommand(of: pasteAcceptedTypes) { providers in
                        handlePaste(providers: providers)
                    }

                VStack(spacing: 6) {
                    if controller.isStreaming {
                        Button("Stop") { controller.cancelGeneration() }
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.error)
                    }
                    Button {
                        submitOrRequestPermission()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(chatBackend == .hermes ? AnyShapeStyle(DesignSystem.Colors.mercuryGradient) : AnyShapeStyle(DesignSystem.Colors.primaryGradient))
                    }
                    .buttonStyle(.plain)
                    .disabled(sendDisabled)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .onDrop(of: [.fileURL, .image, .pdf, .url], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(alignment: .top) {
            if isDropTargeted {
                Text("Drop to attach")
                    .font(DesignSystem.Typography.tiny)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.95))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                chatBackend == .hermes
                                    ? AnyShapeStyle(DesignSystem.Colors.mercuryGradient)
                                    : AnyShapeStyle(DesignSystem.Colors.whimsy),
                                lineWidth: 0.75
                            )
                    )
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    private var cliPermissionPrompt: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.whimsy)
                .frame(width: 22, height: 22)

            Text("Mac CLI assistants are off for \(chatBackend.displayName). Enable them to send this message locally.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: DesignSystem.Spacing.sm)

            Button {
                onRequestCLIAssistantConsent?()
            } label: {
                Label("Enable", systemImage: "lock.open")
            }
            .font(DesignSystem.Typography.tiny)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(DesignSystem.Colors.whimsy.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(DesignSystem.Colors.whimsy.opacity(0.18), lineWidth: 0.75)
        )
    }

    private func submitOrRequestPermission() {
        if shouldRequestCLIAssistantPermission {
            onRequestCLIAssistantConsent?()
            return
        }
        onSubmit()
    }

    // MARK: - Attachment menu

    @ViewBuilder
    private func textExpansionPreview(_ preview: ChatTextExpansionPreviewState) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: preview.isLoading ? "sparkles" : "text.badge.checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                .frame(width: 20, height: 20)
                .opacity(preview.isLoading ? 0.6 : 1.0)
                .animation(preview.isLoading ? DesignSystem.Animation.mercuryPulse : .default, value: preview.isLoading)
                .symbolEffect(.pulse, isActive: preview.isLoading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(preview.title)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text(preview.token)
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.hermesAureate.opacity(0.12))
                        )
                }
                if preview.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let error = preview.errorMessage {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text(error)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.error)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                            Text("Retype trigger to retry")
                                .font(DesignSystem.Typography.tiny)
                        }
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                } else {
                    Text(preview.generatedText)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(4)
                }
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            if !preview.isLoading, preview.errorMessage == nil {
                Button {
                    controller.insertPendingTextExpansionPreview()
                } label: {
                    Label("Insert", systemImage: "return")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Button {
                controller.cancelTextExpansionPreview()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Dismiss snippet preview")
        }
        .padding(DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.75)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(DesignSystem.Colors.mercuryGradient)
                .frame(width: 2.5)
                .padding(.vertical, 4)
                .padding(.leading, 1)
        }
    }

    @ViewBuilder
    private var attachmentMenu: some View {
        Menu {
            Button {
                pickFiles()
            } label: {
                Label("Choose Files…", systemImage: "folder")
            }
            Button {
                pickImagesFromPhotos()
            } label: {
                Label("Photos…", systemImage: "photo.on.rectangle")
            }
            if NSPasteboard.general.canPasteImageOrFile {
                Button {
                    handlePasteboard()
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(
                    chatBackend == .hermes
                        ? AnyShapeStyle(DesignSystem.Colors.hermesAureate)
                        : AnyShapeStyle(DesignSystem.Colors.textSecondary)
                )
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Attach files")
        .frame(width: 32)
    }

    private var pasteAcceptedTypes: [UTType] {
        [.image, .pdf, .fileURL, .url, .text]
    }

    // MARK: - Pickers

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = []
        if panel.runModal() == .OK {
            for url in panel.urls {
                controller.addAttachment(from: url)
            }
        }
    }

    private func pickImagesFromPhotos() {
        // Use NSOpenPanel scoped to the user's Pictures directory + image
        // types so the menu still works on macOS targets where PhotosPicker
        // is unavailable / requires the photos entitlement.
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .pdf]
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK {
            for url in panel.urls {
                controller.addAttachment(from: url)
            }
        }
    }

    private func handlePasteboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            for url in urls { controller.addAttachment(from: url) }
            return
        }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in images { controller.addAttachment(image: image) }
            return
        }
        if let strings = pb.readObjects(forClasses: [NSString.self], options: nil) as? [String], let first = strings.first {
            // Append pasted text to the input field.
            controller.inputText.append(first)
        }
    }

    // MARK: - Drop / paste handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in controller.addAttachment(from: url) }
                }
                handled = true
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    if let image = object as? NSImage {
                        Task { @MainActor in controller.addAttachment(image: image) }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func handlePaste(providers: [NSItemProvider]) {
        _ = handleDrop(providers: providers)
    }

    private func revealAttachment(_ attachment: HermesAttachment) {
        let url = controller.chatWorkspaceURL.appendingPathComponent(attachment.workspaceRelativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([controller.chatWorkspaceURL])
        }
    }
}

private extension NSPasteboard {
    var canPasteImageOrFile: Bool {
        let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .pdf, .URL]
        return availableType(from: types) != nil
    }
}
