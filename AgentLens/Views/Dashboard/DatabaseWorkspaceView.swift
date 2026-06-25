import SwiftUI

// MARK: - Database Workspace View

struct DatabaseWorkspaceView: View {
    @Bindable var dataStore: DataStore

    @Bindable var settingsManager: SettingsManager

    var accountManager: AccountManager

    var cloudSyncService: CloudSyncService?

    @State var mode: DatabaseWorkspaceMode = .story
    @State var deviceSummaries: [DeviceUsageSummary] = []
    @State var showAtlasCostMix = false

    @State var snapshot = DatabaseWorkspaceSnapshot()

    @State var filter = DatabaseWorkspaceFilterState()

    @State var selection: DatabaseWorkspaceSelection?

    @State var appeared = false

    @State var atlasRows: [AtlasCorpusRow] = []

    @State var atlasLoading = false

    @State var atlasError: String?

    @State var snapshotRebuildTask: Task<Void, Never>?

    /// When the query planner detects aggregate intent, show full substring counts over stored transcripts (not top‑K retrieval).
    @State var atlasAggregateSummary: String?

    @State var indexedDocumentDetailCache: [String: SearchDocumentRecord] = [:]
    @State var indexedChunksCache: [String: [SearchChunkRecord]] = [:]
    @State var indexedDetailError: String?
    @State var conversationDetailCache: [String: ConversationRecord] = [:]
    @State var conversationDetailError: String?

    /// Drives the collapsed (icon-only) search affordance used when the command strip is width-starved.
    @State private var searchExpanded = false
    @FocusState private var searchFieldFocused: Bool

    var showInspector: Bool {
        selection != nil && (mode == .atlas || mode == .system)
    }

    var body: some View {
        HStack(spacing: 0) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showInspector, let sel = selection {
                Divider()
                inspectorPanel(for: sel)
                    .frame(width: 380)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DesignSystem.Animation.standard, value: showInspector)
        .background(Color.clear)
        .task { await rebuildSnapshot() }
        .task(id: atlasRefreshKey) { await refreshAtlasRowsIfNeeded() }
        .onChange(of: dataStore.usagesVersion) { _, _ in scheduleSnapshotRebuild() }
        .onChange(of: settingsManager.conversationIndexingEnabled) { _, _ in scheduleSnapshotRebuild() }
        .onChange(of: settingsManager.preferredIndexEmbeddingVersionID) { _, _ in
            scheduleSnapshotRebuild()
            Task { await refreshAtlasRowsIfNeeded() }
        }
        .onChange(of: accountManager.isSignedIn) { _, _ in scheduleSnapshotRebuild() }
        .onDisappear {
            snapshotRebuildTask?.cancel()
            snapshotRebuildTask = nil
        }
    }

    @MainActor
    func rebuildSnapshot() async {
        snapshot = await DatabaseWorkspaceSnapshotBuilder.build(
            from: dataStore,
            settingsManager: settingsManager,
            accountManager: accountManager,
            cloudSyncService: cloudSyncService
        )
    }

    @MainActor
    func scheduleSnapshotRebuild(delay: Duration = .milliseconds(350)) {
        snapshotRebuildTask?.cancel()
        snapshotRebuildTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await rebuildSnapshot()
        }
    }

    var mainContent: some View {
        VStack(spacing: 0) {
            commandStrip
            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    switch mode {
                    case .story:
                        storyContent
                    case .atlas:
                        atlasContent
                    case .system:
                        systemContent
                    }
                }
                .padding(DesignSystem.Spacing.xl)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            withAnimation(DesignSystem.Animation.standard) {
                appeared = true
            }
        }
    }

    var commandStrip: some View {
        ViewThatFits(in: .horizontal) {
            // Tier 1 — full row: title · search · full health pill · mode switcher.
            commandStripRow(search: .full, pill: .full)

            // Tier 2 — collapse the health pill to its title chip (drops the 132pt Coverage row).
            commandStripRow(search: .full, pill: .compact)

            // Tier 3 — search shrinks to an icon-only button (expands on tap) alongside the compact pill.
            commandStripRow(search: .icon, pill: .compact)

            // Tier 4 — last resort: title + compact pill + switcher on top, search on its own row below.
            commandStripStacked
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.4))
    }

    /// Progressive-degradation form of the trailing search control.
    private enum CommandStripSearch { case full, icon }

    /// Progressive-degradation form of the trailing index-health pill.
    private enum CommandStripPill { case full, compact }

    private func commandStripRow(search: CommandStripSearch, pill: CommandStripPill) -> some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            titleColumn

            Spacer(minLength: DesignSystem.Spacing.md)

            if mode == .atlas {
                switch search {
                case .full:
                    searchField
                        .layoutPriority(-1)
                case .icon:
                    searchIconControl
                }
            }

            if snapshot.indexingEnabled {
                switch pill {
                case .full:
                    indexStatusPill
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                case .compact:
                    indexStatusPillCompact
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
            }

            modeSwitcher
        }
    }

    /// Final fallback: keep the title, compact health pill, and mode switcher on the top row,
    /// and drop the full-width search onto its own row so nothing has to overlap.
    private var commandStripStacked: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.lg) {
                titleColumn

                Spacer(minLength: DesignSystem.Spacing.md)

                if snapshot.indexingEnabled {
                    indexStatusPillCompact
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }

                modeSwitcher
            }

            if mode == .atlas {
                searchField
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Database")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6, height: 6)

                Text(statusLabel)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .layoutPriority(-1)
    }

    private var searchField: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            TextField("Search conversations, skills, and agent docs...", text: $filter.searchQuery)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .focused($searchFieldFocused)
                .frame(minWidth: 120, idealWidth: 260, maxWidth: 260)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(
            Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
        )
        .overlay(
            Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    /// Width-tight search: an icon button that reveals a compact inline field once tapped or while a query is active.
    @ViewBuilder
    private var searchIconControl: some View {
        let queryActive = filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if searchExpanded || queryActive {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                TextField("Search...", text: $filter.searchQuery)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .focused($searchFieldFocused)
                    .frame(minWidth: 80, idealWidth: 140, maxWidth: 160)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(
                Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
            )
            .overlay(
                Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            )
            .layoutPriority(-1)
        } else {
            Button {
                searchExpanded = true
                searchFieldFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 24, height: 24)
                    .background(
                        Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                    )
                    .overlay(
                        Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("Search conversations, skills, and agent docs")
        }
    }

    var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(DatabaseWorkspaceMode.allCases) { m in
                Button {
                    withAnimation(DesignSystem.Animation.standard) {
                        mode = m
                    }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: m.icon)
                            .font(.system(size: 10, weight: .medium))
                        Text(m.displayName)
                            .font(DesignSystem.Typography.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(mode == m ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        Capsule().fill(mode == m ? DesignSystem.Colors.surfaceElevated : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .padding(2)
        .background(
            Capsule().fill(DesignSystem.Colors.surface.opacity(0.6))
        )
        .overlay(
            Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    var freshnessLabel: String {
        if let last = snapshot.lastRefresh {
            return "Updated \(last.formatted(date: .omitted, time: .shortened))"
        }
        return "Never scanned"
    }

    var statusDotColor: Color {
        if snapshot.loadIssues.isEmpty == false {
            return DesignSystem.Colors.warning
        }
        if indexingInProgress {
            return DesignSystem.Colors.amber
        }
        if snapshot.retrievalSystemHealth.degradedModes.isEmpty == false {
            return DesignSystem.Colors.warning
        }
        return snapshot.indexingEnabled ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted
    }

    var statusLabel: String {
        if snapshot.loadIssues.isEmpty == false {
            return "Partial data • \(freshnessLabel)"
        }
        if snapshot.indexingEnabled && indexingInProgress {
            let queueDepth = snapshot.retrievalSystemHealth.projectionQueue.queueDepth
            let queueLabel = queueDepth > 0 ? " • \(queueDepth) queued" : ""
            return "Indexing \(Int(sourceCoverageFraction * 100))%\(queueLabel) • \(freshnessLabel)"
        }
        if snapshot.indexingEnabled && snapshot.retrievalSystemHealth.degradedModes.isEmpty == false {
            return "Index degraded • \(freshnessLabel)"
        }
        if snapshot.indexingEnabled {
            return "Index ready • \(freshnessLabel)"
        }
        return freshnessLabel
    }

    var indexStatusPill: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("Health")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)

                Text(indexStatusTitle)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(statusDotColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(statusDotColor.opacity(0.12))
                    )
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                ProgressView(value: sourceCoverageFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 132, height: 6)
                    .fixedSize(horizontal: true, vertical: false)

                Text("Coverage \(indexStatusValue)")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    /// Width-tight health pill: keeps the title chip (and a compact coverage %) but drops the 132pt
    /// Coverage progress row so the command strip can fit a narrow main-content column.
    var indexStatusPillCompact: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("Health")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(1)

            Text(indexStatusTitle)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(statusDotColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, DesignSystem.Spacing.xs)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(statusDotColor.opacity(0.12))
                )

            Text(indexStatusValue)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    func bandMetric(label: String, value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(color ?? DesignSystem.Colors.textPrimary)
        }
    }

    func conversationDetail(id: String) -> ConversationRecord? {
        conversationDetailCache[id]
    }

    @MainActor
    func loadConversationDetail(id: String) async {
        if conversationDetailCache[id] != nil {
            return
        }

        conversationDetailError = nil
        do {
            guard let conversation = try await dataStore.fetchConversation(id: id) else {
                conversationDetailError = "Conversation not found."
                return
            }
            conversationDetailCache[id] = conversation
        } catch {
            AppLogger.dataStore.silentFailure("database_workspace_conversation_detail_fetch_failed", error: error)
            conversationDetailError = error.localizedDescription
        }
    }

    func sourceArtifactDetail(id: String) -> SourceArtifactRecord? {
        snapshot.sourceArtifactRecords.first(where: { $0.id == id })
    }

    @MainActor
    func loadIndexedDocumentDetail(id: String) async {
        if indexedDocumentDetailCache[id] != nil {
            return
        }

        indexedDetailError = nil
        do {
            guard let document = try await dataStore.fetchSearchDocument(id: id) else {
                indexedDetailError = "Indexed document not found."
                return
            }
            let chunks = try await dataStore.fetchSearchChunks(documentID: document.id)
            indexedDocumentDetailCache[id] = document
            indexedChunksCache[document.id] = chunks
        } catch {
            indexedDetailError = error.localizedDescription
        }
    }

    func sharedArtifactSyncState(sourceArtifactID: String) -> SharedArtifactSyncStateRecord? {
        snapshot.syncStates.first(where: { $0.sourceArtifactID == sourceArtifactID })
    }

    func embeddingModel(for version: EmbeddingVersionRecord) -> EmbeddingModelRecord? {
        snapshot.embeddingModelRecords.first(where: { $0.id == version.modelID })
    }

    var semanticEmbeddingVersion: EmbeddingVersionRecord? {
        guard let versionID = snapshot.retrievalSystemHealth.semanticPipeline.embeddingVersionID else { return nil }
        return snapshot.embeddingVersionRecords.first(where: { $0.id == versionID })
    }

    var selectedEmbeddingVersion: EmbeddingVersionRecord? {
        if let preferredVersionID = settingsManager.preferredIndexEmbeddingVersionIDValue,
           let preferredVersion = snapshot.embeddingVersionRecords.first(where: { $0.id == preferredVersionID }) {
            return preferredVersion
        }
        return semanticEmbeddingVersion
            ?? snapshot.embeddingVersionRecords.first(where: \.isActive)
            ?? snapshot.embeddingVersionRecords.first
    }

    var selectedEmbeddingVersionLabel: String {
        guard let version = selectedEmbeddingVersion else { return "Automatic" }
        return embeddingVersionShortLabel(version)
    }

    var selectionWarning: String? {
        guard
            let selectedVersion = selectedEmbeddingVersion,
            let semanticVersionID = snapshot.retrievalSystemHealth.semanticPipeline.embeddingVersionID,
            selectedVersion.id != semanticVersionID
        else {
            return nil
        }

        return "The selected index version differs from the currently served semantic version. OpenBurnBar will prefer the selected version for new retrieval sessions, but queued or stale embeddings can still leave search in lexical fallback until re-embedding catches up."
    }

    var indexableSourceCount: Int {
        snapshot.totalConversations + snapshot.sourceArtifacts
    }

    var sourceCoverageFraction: Double {
        guard indexableSourceCount > 0 else {
            return snapshot.indexedDocuments > 0 ? 1 : 0
        }
        return min(1, Double(snapshot.indexedDocuments) / Double(indexableSourceCount))
    }

    var semanticCoverageFraction: Double {
        guard snapshot.indexedChunks > 0 else {
            return snapshot.embeddedChunks > 0 ? 1 : 0
        }
        return min(1, Double(snapshot.embeddedChunks) / Double(snapshot.indexedChunks))
    }

    var indexingInProgress: Bool {
        snapshot.retrievalSystemHealth.rebuild.inProgress
            || snapshot.projectionJobCounts.active > 0
            || snapshot.projectionJobCounts.queued > 0
    }

    var indexStatusTitle: String {
        if indexingInProgress {
            return "Indexing"
        }
        if snapshot.retrievalSystemHealth.degradedModes.isEmpty == false {
            return "Degraded"
        }
        return "Ready"
    }

    var indexStatusValue: String {
        if indexingInProgress {
            return "\(snapshot.indexedDocuments)/\(max(indexableSourceCount, snapshot.indexedDocuments))"
        }
        return "\(Int(sourceCoverageFraction * 100))%"
    }

    func embeddingDisplayName(model: EmbeddingModelRecord, version: EmbeddingVersionRecord) -> String {
        "\(model.provider) / \(model.modelName) • \(version.versionTag)"
    }

    func embeddingVersionShortLabel(_ version: EmbeddingVersionRecord) -> String {
        if let model = embeddingModel(for: version) {
            return "\(model.modelName) • \(version.versionTag)"
        }
        return version.versionTag
    }

    func embeddingVersionMenuLabel(_ version: EmbeddingVersionRecord) -> String {
        if let model = embeddingModel(for: version) {
            return "\(model.provider) / \(model.modelName) • \(version.versionTag)"
        }
        return version.id
    }

    func inspectorRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    func inspectorSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .textCase(.uppercase)
    }

    func inspectorChunkRow(_ chunk: SearchChunkRecord, embeddingVersionID: String?) -> some View {
        let isEmbedded = false

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                Text("#\(chunk.ordinal)")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                if let sectionPath = chunk.sectionPath, sectionPath.isEmpty == false {
                    Text(sectionPath)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                Circle()
                    .fill(isEmbedded ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                    .frame(width: 6, height: 6)

                Text(isEmbedded ? "Embedded" : "Not embedded")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(isEmbedded ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
            }

            Text(chunk.text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("Offsets \(chunk.startOffset)-\(chunk.endOffset)")
                if let start = chunk.messageStartOffset, let end = chunk.messageEndOffset {
                    Text("Msg \(start)-\(end)")
                }
            }
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    func inspectorTextBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func prettyPrintedJSON(_ json: String?) -> String? {
        guard
            let json,
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return json
        }
        return pretty
    }

    func indexProgressRow(label: String, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text(label)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            ProgressView(value: max(0.0, min(1.0, fraction)))
                .progressViewStyle(.linear)

            Text(detail)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    func tableHeader(_ title: String, width: CGFloat?) -> some View {
        let header = Text(title)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .textCase(.uppercase)

        if let width {
            header.frame(width: width, alignment: .leading)
        } else {
            header.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func atlasFilterMenu<Content: View>(
        title: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(value)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.45)))
            .overlay(
                Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .padding(.vertical, DesignSystem.Spacing.sm)
    }

    func unavailableLabel(_ text: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    var partialDataBand: some View {
        WideBand(title: "Partial Data") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Some database metrics could not be loaded. Values marked unavailable are not trustworthy until the next successful refresh.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                ForEach(snapshot.loadIssues.prefix(6)) { issue in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                        Circle()
                            .fill(DesignSystem.Colors.warning)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.context.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text(issue.message)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    var atlasRefreshKey: AtlasRefreshKey {
        AtlasRefreshKey(
            mode: mode,
            filter: filter,
            contentVersion: snapshot.contentVersion
        )
    }

    var hasActiveFilters: Bool {
        filter.providerFilter != nil
            || filter.sourceKindFilter != nil
            || filter.projectFilter != nil
            || filter.timeWindow != .allTime
            || filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var atlasSummaryText: String {
        let trimmedQuery = filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedQuery.isEmpty
            ? "Showing \(atlasRows.count) indexed records"
            : "Found \(atlasRows.count) matching records"

        var qualifiers: [String] = []
        if let provider = filter.providerFilter {
            qualifiers.append(provider.displayName)
        }
        if let sourceKind = filter.sourceKindFilter {
            qualifiers.append(sourceKind.databaseDisplayName)
        }
        if let projectFilter = filter.projectFilter, projectFilter.isEmpty == false {
            qualifiers.append(projectFilter)
        }
        if filter.timeWindow != .allTime {
            qualifiers.append(filter.timeWindow.displayName)
        }

        guard qualifiers.isEmpty == false else { return base }
        return ([base] + qualifiers).joined(separator: " • ")
    }

    func metricValue(_ value: Int, for metric: DatabaseWorkspaceMetric) -> String {
        snapshot.unavailableMetrics.contains(metric) ? "Unavailable" : "\(value)"
    }

    var atlasArtifactTypes: Set<SearchSourceKind>? {
        guard let sourceKind = filter.sourceKindFilter else { return nil }
        return [sourceKind]
    }

    var atlasDateRange: ClosedRange<Date>? {
        filter.timeWindow.dateRange()
    }

    @MainActor
    func refreshAtlasRowsIfNeeded() async {
        guard mode == .atlas else { return }
        atlasLoading = true
        atlasError = nil
        atlasAggregateSummary = nil

        let trimmedQuery = filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedQuery.isEmpty {
            do {
                let documents = try await dataStore.fetchSearchDocuments(
                    limit: 120,
                    provider: filter.providerFilter,
                    projectName: filter.projectFilter,
                    sourceKinds: atlasArtifactTypes.map(Array.init),
                    dateRange: atlasDateRange
                )
                atlasRows = documents.map(AtlasCorpusRow.init(document:))
            } catch {
                atlasRows = []
                atlasError = "Unable to load indexed corpus: \(error.localizedDescription)"
            }
            atlasLoading = false
            return
        }

        let searchService = await SearchService.makeConversationSearchServiceUsingStoredEmbeddings(
            dataStore: dataStore,
            settingsManager: settingsManager
        )
        let run = await searchService.runBurnBarQuery(
            RetrievalQuery(
                text: trimmedQuery,
                filters: RetrievalFilters(
                    provider: filter.providerFilter,
                    projectName: filter.projectFilter,
                    artifactTypes: atlasArtifactTypes,
                    dateRange: atlasDateRange
                ),
                lexicalCandidateLimit: 180,
                semanticCandidateLimit: 180,
                rerankCandidateLimit: 220,
                resultLimit: 120
            )
        )
        atlasRows = run.retrievalResults.map(AtlasCorpusRow.init(retrievalResult:))
        if let count = run.aggregateOccurrenceCount, run.plan.aggregatePatterns.isEmpty == false {
            atlasAggregateSummary =
                "Complete substring count over indexed transcripts (case-insensitive): \(count) — patterns: \(run.plan.aggregatePatterns.joined(separator: ", "))"
        }
        atlasLoading = false
    }

    var indexingDisabledState: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 48))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text("Indexing is disabled")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Enable conversation indexing to populate the Database workspace with search, coverage, and system data.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                settingsManager.conversationIndexingEnabled = true
            } label: {
                Text("Enable Indexing")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(Capsule().fill(DesignSystem.Colors.blaze))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.xxxl)
    }

    func jobStatusColor(_ status: ProjectionJobStatus) -> Color {
        switch status {
        case .completed: return DesignSystem.Colors.success
        case .running, .leased: return DesignSystem.Colors.amber
        case .queued: return DesignSystem.Colors.textMuted
        case .failed: return DesignSystem.Colors.error
        case .canceled: return DesignSystem.Colors.textMuted
        }
    }

    func healthStatusColor(_ status: RetrievalHealthStatus) -> Color {
        switch status {
        case .healthy: return DesignSystem.Colors.success
        case .degraded: return DesignSystem.Colors.warning
        case .failed: return DesignSystem.Colors.error
        }
    }

    func auditActionIcon(_ action: SharedArtifactAuditAction) -> String {
        switch action {
        case .create: return "plus.circle"
        case .update: return "pencil.circle"
        case .share: return "person.2"
        case .permissionChange: return "lock.rotation"
        case .rebuild: return "arrow.clockwise"
        case .conflictDetected: return "exclamationmark.triangle"
        case .conflictResolved: return "checkmark.circle"
        }
    }

}
