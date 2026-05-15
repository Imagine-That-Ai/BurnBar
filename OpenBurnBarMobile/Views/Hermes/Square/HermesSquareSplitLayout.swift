import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Square Split Layout (Hermes Square §6.11 / S6)
//
// iPad-adaptive two-column layout that activates at width ≥ 720pt. Thread
// list + pinned grid live on the left; active thread / mission situation
// room lives on the right. Below 720pt, this view delegates back to
// `HermesSquareRoot` (the single-column phone layout) so iPhone is
// unaffected.

struct HermesSquareSplitLayout: View {
    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost

    @State private var selectedDetail: DetailRoute? = nil

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 720 {
                twoColumnLayout
            } else {
                HermesSquareRoot(
                    hermesService: hermesService,
                    missionHost: missionHost
                )
            }
        }
    }

    private var twoColumnLayout: some View {
        NavigationSplitView {
            HermesSquareLeftColumn(
                hermesService: hermesService,
                missionHost: missionHost,
                onSelect: { route in selectedDetail = route }
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 380)
        } detail: {
            HermesSquareDetailColumn(
                hermesService: hermesService,
                missionHost: missionHost,
                detail: selectedDetail
            )
        }
        .navigationSplitViewStyle(.balanced)
    }

    enum DetailRoute: Hashable {
        case thread(String)        // thread inbox id
        case mission(String)       // mission id
        case brandZone(String)     // agent URI
    }
}

// MARK: - Left column

private struct HermesSquareLeftColumn: View {
    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost
    let onSelect: (HermesSquareSplitLayout.DetailRoute) -> Void

    @State private var registry = AgentIdentityRegistry.shared
    @State private var inbox = ThreadInboxStore(missionHost: nil)

    @AppStorage(PinnedAgentGridConfig.userDefaultsKey) private var pinnedJSON: String = ""

    private var pinnedGrid: PinnedAgentGridConfig {
        PinnedAgentGridConfig.from(jsonString: pinnedJSON)
    }

    var body: some View {
        List {
            Section("Pinned") {
                ForEach(pinnedGrid.pinnedURIs, id: \.self) { uri in
                    if let identity = registry.identity(for: uri) {
                        Button {
                            onSelect(.brandZone(uri))
                        } label: {
                            HStack {
                                HermesSquareAgentAvatar(
                                    identity: identity,
                                    size: 24,
                                    showAvailability: true,
                                    ringStroke: false
                                )
                                Text(identity.displayName)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Active missions") {
                if missionHost.snapshot.activeTiles.isEmpty {
                    Text("None right now.")
                        .foregroundStyle(DesignSystemColors.textMuted)
                        .font(.caption)
                } else {
                    ForEach(missionHost.snapshot.activeTiles) { tile in
                        Button {
                            onSelect(.mission(tile.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tile.title)
                                    .font(.callout.bold())
                                    .lineLimit(1)
                                Text(tile.phase.displayLabel)
                                    .font(.caption2)
                                    .foregroundStyle(DesignSystemColors.textMuted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Conversations") {
                let (service, _) = inbox.items.splitForInbox()
                ForEach(service) { item in
                    Button {
                        onSelect(.thread(item.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.callout.bold())
                                .lineLimit(1)
                            Text(item.preview)
                                .font(.caption)
                                .foregroundStyle(DesignSystemColors.textMuted)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Hermes Square")
        .task {
            inbox.bind(missionHost: missionHost)
            await inbox.refresh()
            await registry.refresh(hermesService: hermesService, missionHost: missionHost)
        }
    }
}

// MARK: - Detail column

private struct HermesSquareDetailColumn: View {
    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost
    let detail: HermesSquareSplitLayout.DetailRoute?

    @State private var registry = AgentIdentityRegistry.shared

    var body: some View {
        switch detail {
        case .none:
            placeholder
        case .thread(let id):
            VStack(alignment: .leading, spacing: 10) {
                Text("Thread")
                    .font(.headline)
                Text(id)
                    .font(.caption.monospaced())
                    .foregroundStyle(DesignSystemColors.textMuted)
                Text("Open the thread on iPhone to inspect; the iPad split-view will gain a thread renderer in a follow-up.")
                    .font(.body)
                    .foregroundStyle(DesignSystemColors.textSecondary)
            }
            .padding()
        case .mission(let id):
            VStack(alignment: .leading, spacing: 10) {
                Text("Mission")
                    .font(.headline)
                Text(id)
                    .font(.caption.monospaced())
                    .foregroundStyle(DesignSystemColors.textMuted)
                if let tile = missionHost.snapshot.activeTiles.first(where: { $0.id == id }) {
                    HermesSquareMissionTile(tile: tile).frame(maxWidth: 360)
                }
            }
            .padding()
        case .brandZone(let uri):
            if let identity = registry.identity(for: uri) {
                AgentBrandZoneView(identity: identity, registry: registry)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 36))
                .foregroundStyle(DesignSystemColors.textMuted)
            Text("Pick a thread, mission, or pinned agent on the left.")
                .font(.callout)
                .foregroundStyle(DesignSystemColors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
