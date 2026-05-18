import SwiftUI
import OpenBurnBarCore

/// Settings → Media → "Per-partner save preferences" surface for
/// Decision 3 of the Mercury media plan. Lists each paired Mac with its
/// current image-save preference and offers per-row reset + global
/// "Forget all".
@MainActor
struct PerPartnerSavePreferencesView: View {
    @State private var partners: [PartnerEntry] = []
    @State private var loading: Bool = true
    private let store: MediaPartnerSavePreferenceStore

    init(store: MediaPartnerSavePreferenceStore = .shared) {
        self.store = store
    }

    var body: some View {
        List {
            Section {
                if loading {
                    HStack {
                        ProgressView()
                        Text("Loading saved partners…")
                            .foregroundStyle(.secondary)
                    }
                } else if partners.isEmpty {
                    Text("No saved partners yet. Once you save your first image from a paired Mac, the choice will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(partners) { partner in
                        partnerRow(partner)
                    }
                }
            } header: {
                Text("Per-partner save preferences")
            } footer: {
                Text("First image from a paired Mac asks where to save. Future images use the choice you make.")
            }

            if !partners.isEmpty {
                Section {
                    Button(role: .destructive) {
                        Task {
                            await store.forgetAll()
                            await reload()
                        }
                    } label: {
                        Text("Forget all")
                    }
                }
            }
        }
        .navigationTitle("Media")
        .task { await reload() }
    }

    @ViewBuilder
    private func partnerRow(_ partner: PartnerEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: partner.peerDeviceId))
                    .font(.body)
                Text(partner.preference.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                Task {
                    await store.forget(peerDeviceId: partner.peerDeviceId)
                    await reload()
                }
            } label: {
                Text("Forget")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
        }
    }

    private func displayName(for peerDeviceId: String) -> String {
        // peerDeviceId is the iroh NodeId (52-char base32). Show the
        // first 6 + last 4 so the user can disambiguate without
        // surfacing the whole secret on screen.
        guard peerDeviceId.count > 12 else { return peerDeviceId }
        let prefix = peerDeviceId.prefix(6)
        let suffix = peerDeviceId.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    private func reload() async {
        loading = true
        let stored = await store.storedPartners()
        partners = stored.map { PartnerEntry(peerDeviceId: $0.peerDeviceId, preference: $0.preference) }
        loading = false
    }
}

private struct PartnerEntry: Identifiable, Equatable {
    let peerDeviceId: String
    let preference: MediaPartnerSavePreferenceStore.SavePreference

    var id: String { peerDeviceId }
}

private extension MediaPartnerSavePreferenceStore.SavePreference {
    var label: String {
        switch self {
        case .askEachTime: return "Ask each time"
        case .photos: return "Save to Photos"
        case .files: return "Save to Files"
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PerPartnerSavePreferencesView()
    }
}
#endif
