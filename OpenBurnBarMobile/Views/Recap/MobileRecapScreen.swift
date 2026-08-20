import SwiftUI
import OpenBurnBarCore
import OpenBurnBarUI

/// The monthly recap on iPhone and iPad.
///
/// Renders the same `RecapDeckView` the Mac does — the deck adapts to one or two
/// columns from the width it is given, so there is no phone-specific card
/// system to keep in sync.
struct MobileRecapScreen: View {

    /// Set when presented modally from the Insights tab on iPhone, so the sheet
    /// has a way out. Nil when it is a first-class destination on iPad.
    var onDismiss: (() -> Void)?

    @State private var environment: MobileRecapEnvironment?
    @State private var setupError: String?
    @State private var pendingExport: RecapExport?
    @AppStorage(MobileRecapEnvironment.aiToggleKey) private var editorialEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Recap")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .background(MobileTheme.Colors.background.ignoresSafeArea())
        }
        .task { await setUpIfNeeded() }
        .onDisappear { environment?.cancel() }
        .onChange(of: editorialEnabled) { environment?.load() }
        .sheet(item: $pendingExport) { export in
            RecapSharePreviewSheet(export: export)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let setupError {
            RecapEmptyStateView(reason: .failed(setupError))
                .padding()
        } else if let environment {
            switch environment.phase {
            case .idle, .building, .ready:
                if let recap = environment.recap {
                    ScrollView {
                        RecapDeckView(
                            recap: recap,
                            onShareCard: { card in export(card: card, window: recap.window) },
                            onShareRecap: { export(recap: recap) }
                        )
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .padding(.top, MobileTheme.Spacing.lg)
                        .padding(.bottom, MobileTheme.Spacing.xxxl)
                        .animation(reduceMotion ? nil : MobileTheme.Animation.gentle,
                                   value: recap.isVoiceAuthored)
                    }
                    .recapScrollEdgeSoftening()
                } else {
                    loading
                }
            case let .notEnoughData(window):
                ScrollView {
                    RecapEmptyStateView(reason: .notEnoughActivity(window)).padding()
                }
            case let .failed(message):
                ScrollView {
                    RecapEmptyStateView(reason: .failed(message)).padding()
                }
            }
        } else {
            loading
        }
    }

    private var loading: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            ProgressView()
            Text("Reading your month…")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let onDismiss {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done", action: onDismiss)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let environment {
                    Picker("Month", selection: Binding(
                        get: { environment.selectedMonth },
                        set: { environment.select($0) }
                    )) {
                        ForEach(environment.availableMonths) { month in
                            Text(month.displayLabel()).tag(month)
                        }
                    }
                }
                Divider()
                Toggle(isOn: $editorialEnabled) {
                    Label("Let AI write it", systemImage: "sparkles")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Recap options")
        }
    }

    // MARK: Setup

    private func setUpIfNeeded() async {
        guard environment == nil, setupError == nil else { return }
        do {
            let created = try MobileRecapEnvironment()
            environment = created
            await created.refreshAvailableMonths()
            created.load()
        } catch {
            setupError = error.localizedDescription
        }
    }

    // MARK: Export

    /// Writes the PNG to a temp file and hands it to the share sheet — a URL
    /// gives the receiving app a real filename instead of an untitled blob.
    private func export(card: RecapCard, window: RecapWindow) {
        let renderer = RecapShareCardRenderer()
        guard let data = renderer.png(card: card, window: window) else { return }
        present(data, named: renderer.suggestedFilename(for: window, cardID: card.id))
    }

    private func export(recap: MonthlyRecap) {
        let renderer = RecapShareCardRenderer()
        guard let data = renderer.png(recap: recap) else { return }
        present(data, named: renderer.suggestedFilename(for: recap.window))
    }

    private func present(_ data: Data, named name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        pendingExport = RecapExport(url: url)
    }
}

// MARK: - Share preview

struct RecapExport: Identifiable {
    let url: URL
    var id: String { url.lastPathComponent }
}

/// Shows the rendered card before it goes anywhere.
///
/// A share sheet fired straight from a tap sends an image the person has not
/// seen. This is one extra tap in exchange for knowing what you are about to
/// post — the right trade for something designed to be posted.
struct RecapSharePreviewSheet: View {
    let export: RecapExport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let image = UIImage(contentsOfFile: export.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
                        .padding()
                        .accessibilityLabel("Preview of the card you are about to share")
                }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .background(MobileTheme.Colors.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: export.url, preview: SharePreview("Your month with AI")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

// MARK: - Entry banner

/// The pinned "Your August with AI" card at the top of the Insights tab.
///
/// On iPhone the tray is already six destinations deep, and a surface that
/// matters once a month does not earn a seventh permanent slot. This banner is
/// how the recap gets found there instead — unmissable in the month it lands,
/// and quiet the rest of the time.
struct RecapEntryBanner: View {

    let window: RecapWindow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MobileTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(MobileTheme.amber.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(MobileTheme.amber)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Your \(window.monthLabel()) with AI")
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("A month of your AI work, read back to you")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            .padding(MobileTheme.Spacing.lg)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .strokeBorder(MobileTheme.amber.opacity(0.28), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open your \(window.monthLabel()) recap")
        .accessibilityAddTraits(.isButton)
    }
}
