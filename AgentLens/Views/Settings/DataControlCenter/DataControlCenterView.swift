import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenBurnBarCore

// MARK: - Data & Privacy Control Center (macOS governance workbench)
//
// The single surface where a member governs every facet of their data. Three
// regions:
//   1. NavigationSplitView sidebar — the 12 registry domains grouped by
//      encryption tier, each with its tier dot and live count.
//   2. Content — a sortable, bordered inventory Table (domain · tier · count ·
//      bytes · retention) above the Basin (mercury swirl bound to the sealed
//      fraction), inside an HSplitView whose trailing pane is the domain
//      inspector (footprint chart + yours↔server flip + paths + actions).
//   3. A persistent governance toolbar (Refresh · Export all · Set up recovery ·
//      Panic) plus a tier-summary header.
//
// Everything binds to the generated registry (`DataDomains.all`) and the design
// tokens (via `PensieveTheme`) — no hardcoded domain list or colors. All
// mutations route through `DataControlCenterViewModel`'s callable hub.

struct DataControlCenterView: View {
    @State private var viewModel: DataControlCenterViewModel
    @State private var selectedDomainID: String?
    @State private var sortOrder = [KeyPathComparator(\DataControlCenterViewModel.DomainRow.bytes, order: .reverse)]

    @State private var showRecoverySheet = false
    @State private var showPanicSheet = false
    @State private var deleteTarget: DataControlCenterViewModel.DomainRow?
    @State private var exportScope: ExportScope?

    init(accountManager: AccountManager = .shared) {
        _viewModel = State(initialValue: DataControlCenterViewModel(accountManager: accountManager))
    }

    /// Identifies a pending export so the file-save panel knows what to write.
    private enum ExportScope: Identifiable, Equatable {
        case all
        case domain(String)
        var id: String {
            switch self {
            case .all: return "all"
            case .domain(let id): return id
            }
        }
        var domains: [String]? {
            switch self {
            case .all: return nil
            case .domain(let id): return [id]
            }
        }
        var filenameStem: String {
            switch self {
            case .all: return "burnbar-data-export"
            case .domain(let id): return "burnbar-\(id)-export"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detail
        }
        .navigationTitle("Data & Privacy")
        .toolbar { toolbarContent }
        .task {
            await viewModel.refreshUsage()
            if selectedDomainID == nil { selectedDomainID = viewModel.rows.first?.id }
        }
        .sheet(isPresented: $showRecoverySheet) {
            RecoverySetupSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showPanicSheet) {
            PanicRevokeSheet(viewModel: viewModel)
        }
        .sheet(item: $deleteTarget) { target in
            DeleteDomainSheet(viewModel: viewModel, domain: target.domain)
        }
        .onChange(of: exportScope) { _, scope in
            guard let scope else { return }
            Task { await runExport(scope) }
        }
    }

    // MARK: Sidebar (grouped by tier)

    private var sidebar: some View {
        List(selection: $selectedDomainID) {
            tierSection(.endToEnd, header: "End-to-end")
            tierSection(.zeroAccess, header: "Zero-access")
            tierSection(.serverReadable, header: "Server-readable")
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    @ViewBuilder
    private func tierSection(_ tier: EncryptionTier, header: String) -> some View {
        let domainRows = viewModel.rows.filter { $0.tier == tier }
        if domainRows.isEmpty == false {
            Section {
                ForEach(domainRows) { row in
                    sidebarRow(row)
                        .tag(row.id)
                }
            } header: {
                Label(header, systemImage: tier.iconName)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.0)
                    .foregroundStyle(tier.tint)
            }
        }
    }

    private func sidebarRow(_ row: DataControlCenterViewModel.DomainRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.domain.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(row.tier.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if row.count > 0 {
                    Text("\(row.count) records")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.tier.displayLabel), \(row.count) records")
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: tierIcon)
                    .foregroundStyle(PensieveTheme.brassCore)
                Text(tierSummary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var tierIcon: String {
        switch viewModel.tier {
        case .ultra: return "crown.fill"
        case .pro: return "sparkles"
        case .free: return "cloud"
        }
    }

    private var tierSummary: String {
        switch viewModel.tier {
        case .ultra: return "Ultra plan"
        case .pro: return "Cloud Pro plan"
        case .free: return "Free plan"
        }
    }

    // MARK: Detail (Basin + Table + Inspector)

    private var detail: some View {
        ZStack {
            EmberSurfaceBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                if let error = viewModel.usageError {
                    errorBanner(error)
                }
                HSplitView {
                    inventoryColumn
                        .frame(minWidth: 360, idealWidth: 460)
                    inspectorColumn
                        .frame(minWidth: 360)
                }
            }
        }
    }

    private var inventoryColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            DataBasinView(fill: viewModel.sealedFraction, caption: basinCaption)
                .padding([.horizontal, .top], 16)

            inventoryTable
                .settingsAnchor(DataControlCenterAnchors.inventory)
        }
    }

    private var basinCaption: String {
        let pct = Int((viewModel.sealedFraction * 100).rounded())
        return "\(pct)% sealed"
    }

    private var inventoryTable: some View {
        Table(of: DataControlCenterViewModel.DomainRow.self, selection: $selectedDomainID, sortOrder: $sortOrder) {
            TableColumn("Domain", value: \.title) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.domain.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(row.tier.tint)
                    Text(row.title).font(.system(size: 12))
                }
            }
            .width(min: 150, ideal: 190)

            TableColumn("Tier") { row in
                TierBadge(tier: row.tier)
            }
            .width(min: 120, ideal: 140)

            TableColumn("Records", value: \.count) { row in
                Text("\(row.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Stored", value: \.bytes) { row in
                Text(row.bytes > 0 ? Self.byteFormatter.string(fromByteCount: row.bytes) : "—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Retention", value: \.retention) { row in
                Text(row.retention.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .width(min: 100, ideal: 130)
        } rows: {
            ForEach(viewModel.rows.sorted(using: sortOrder)) { row in
                TableRow(row)
                    .contextMenu {
                        domainContextMenu(row)
                    }
            }
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .padding([.horizontal, .bottom], 16)
    }

    @ViewBuilder
    private func domainContextMenu(_ row: DataControlCenterViewModel.DomainRow) -> some View {
        if row.domain.actions.contains("export") {
            Button {
                exportScope = .domain(row.id)
            } label: {
                Label("Export \(row.title)", systemImage: "square.and.arrow.up")
            }
        }
        if row.domain.actions.contains("delete") {
            Button(role: .destructive) {
                deleteTarget = row
            } label: {
                Label("Delete \(row.title)…", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var inspectorColumn: some View {
        if let id = selectedDomainID, let row = viewModel.row(for: id) {
            DomainInspector(
                viewModel: viewModel,
                row: row,
                onDelete: { deleteTarget = row },
                onRecover: { showRecoverySheet = true },
                onExportDomain: { exportScope = .domain(row.id) }
            )
        } else {
            emptyInspector
        }
    }

    private var emptyInspector: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .font(.system(size: 26))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("Select a data domain to inspect it.")
                .font(.system(size: 13))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(DesignSystem.Colors.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DesignSystem.Colors.warning.opacity(0.1))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await viewModel.refreshUsage() }
            } label: {
                if viewModel.isLoadingUsage {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(viewModel.isLoadingUsage)
            .help("Refresh your data footprint")

            Button {
                exportScope = .all
            } label: {
                Label("Export all", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(viewModel.isExporting)
            .help("Export all of your data")

            Button {
                showRecoverySheet = true
            } label: {
                Label("Recovery", systemImage: "key.horizontal.fill")
            }
            .help("Set up recovery before zero-knowledge mode")

            Button(role: .destructive) {
                showPanicSheet = true
            } label: {
                Label("Panic", systemImage: "exclamationmark.octagon.fill")
            }
            .tint(PensieveTheme.waxCrimson)
            .help("Revoke all access immediately")
        }
    }

    // MARK: Export (NSSavePanel — matches the repo's macOS export convention)

    @MainActor
    private func runExport(_ scope: ExportScope) async {
        defer { exportScope = nil }
        guard let data = await viewModel.exportData(domains: scope.domains) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(scope.filenameStem).json"
        panel.allowedContentTypes = [.json]
        panel.title = "Export your data"
        panel.message = "Plaintext-facet domains are inline; sealed domains include signed-URL references your devices decrypt."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            viewModel.setExportWriteError(error)
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
}
