import SwiftUI
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore
import OpenBurnBarSignalCore

// MARK: - Pensieve memory search
//
// The search surface for the member's private semantic memory. The whole point
// of Pensieve's E2EE design is preserved here: the query is embedded + cloaked
// ON DEVICE (never sent as plaintext), the server runs ANN over cloaked vectors
// it can't read, and every returned hit's sealed ciphertext + metadata is
// decrypted ON DEVICE with the vault key. This mirrors the hosted MCP shim's
// knowledge.ts request/response transform, in Swift.
//
// Intended to host the `Tab(role: .search)` memory experience. Because the app
// uses the custom Aurora nav tray rather than a native TabView, this view is
// presented from the Control Center / You tab; when wired into a native
// `TabView`, drop it into a `Tab("Memory", systemImage: "brain", role: .search)`.

struct PensieveMemorySearchView: View {
    @State private var query = ""
    @State private var hits: [PensieveMemoryHit] = []
    @State private var isSearching = false
    @State private var error: String?
    @State private var hasSearched = false
    @State private var showCloudStore = false

    @Environment(\.cloudSubscriptionStore) private var cloudStore

    private let searcher: any PensieveMemorySearching

    init(searcher: any PensieveMemorySearching = FunctionsPensieveMemorySearcher()) {
        self.searcher = searcher
    }

    /// Pensieve agent memory is a Cloud Pro feature (Data Vault). Locked users
    /// get the full-screen feature veil over a blurred teaser of the search
    /// surface; the live query path never runs until they're on Cloud Pro.
    private var isUnlocked: Bool { (cloudStore?.cloudTier ?? .none).satisfies(.pro) }

    var body: some View {
        Group {
            if isUnlocked {
                searchScreen
            } else {
                lockedVeil
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showCloudStore) {
            NavigationStack {
                CloudStoreView(onClose: { showCloudStore = false })
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var searchScreen: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            content
        }
        .searchable(text: $query, prompt: "Search your private memory")
        .onSubmit(of: .search) { runSearch() }
    }

    private var lockedVeil: some View {
        LockedFeatureVeil(
            feature: GatedFeature.gatedFeature(.dataVault),
            priceLine: cloudStore.map { TierPricing.priceLine(for: .pro, store: $0) } ?? nil,
            action: {
                Haptics.medium()
                showCloudStore = true
            },
            background: {
                PensieveMemoryTeaserBackground()
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            ProgressView("Embedding & searching on device…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            AuroraStatePane(
                kind: .error,
                icon: "exclamationmark.icloud",
                title: "Search unavailable",
                message: error
            )
        } else if hits.isEmpty {
            AuroraStatePane(
                kind: .empty,
                icon: hasSearched ? "magnifyingglass" : "brain.head.profile",
                title: hasSearched ? "No memories matched" : "Search your Pensieve",
                message: hasSearched
                    ? "Try different words — recall runs over your sealed, cloaked vectors."
                    : "Your repo docs, notes, and chat memories. Embedded and decrypted only on this device."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: MobileTheme.Spacing.sm) {
                    ForEach(hits) { hit in PensieveMemoryHitRow(hit: hit) }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.vertical, MobileTheme.Spacing.md)
            }
        }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        isSearching = true
        error = nil
        hasSearched = true
        Task {
            defer { isSearching = false }
            do {
                hits = try await searcher.search(query: trimmed)
            } catch {
                self.error = error.localizedDescription
                hits = []
            }
        }
    }
}

// MARK: - Locked teaser background
//
// Static glassy "memory hit" cards suggesting the Pensieve recall surface,
// blurred behind the feature veil. Drives no Firebase / no search so locked
// users never pay for work they can't see.

private struct PensieveMemoryTeaserBackground: View {
    var body: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            ForEach(0..<5, id: \.self) { idx in
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                EncryptionTier.endToEnd.tierColor.opacity(0.16 - Double(idx) * 0.015),
                                UnifiedDesignSystem.Colors.whimsy.opacity(0.10),
                                UnifiedDesignSystem.Colors.amber.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 84)
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(EncryptionTier.endToEnd.tierColor.opacity(0.4))
                            .padding(16)
                    }
            }
        }
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
        .padding(.top, MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Hit model

struct PensieveMemoryHit: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    let sourcePath: String?
    let title: String?
    let category: String?
    let score: Double
}

private struct PensieveMemoryHitRow: View {
    let hit: PensieveMemoryHit

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let title = hit.title, !title.isEmpty {
                        Text(title)
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                    }
                    Spacer()
                    if let category = hit.category, !category.isEmpty {
                        Text(category.uppercased())
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(EncryptionTier.endToEnd.tierColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(EncryptionTier.endToEnd.tierColor.opacity(0.14)))
                    }
                }
                Text(hit.text)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = hit.sourcePath, !path.isEmpty {
                    Label(path, systemImage: "doc.text")
                        .font(MobileTheme.Typography.monoTiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Searcher seam

protocol PensieveMemorySearching: Sendable {
    func search(query: String) async throws -> [PensieveMemoryHit]
}

/// Live searcher: embed + cloak the query on device, call the hosted knowledge
/// search callable with the cloaked queryVector + pinned model version, then
/// decrypt each sealed hit with the vault key. Query text never leaves the
/// device; ranking happens over cloaked vectors only.
///
/// NOTE: this depends on a client-facing `searchKnowledge` callable (the natural
/// analog of the hosted MCP `burnbar_search_knowledge` tool). See the handoff —
/// the callable must accept { queryVector:[384], embeddingModelVersion, limit }
/// and return { hits:[{ ciphertext, sealedMetadata, score }] }, exactly the
/// shape knowledge.ts already produces for the MCP path.
struct FunctionsPensieveMemorySearcher: PensieveMemorySearching {
    let limit: Int

    init(limit: Int = 20) { self.limit = limit }

    func search(query: String) async throws -> [PensieveMemoryHit] {
        guard let uid = await AuthRepository.shared.currentUser?.uid else {
            throw DataVaultError.notSignedIn
        }
        let vaultKey = try CloudVaultKeyStore().getOrCreateKey(uid: uid)
        let cloaked = PensieveVectorCloak.embedAndCloak(query, vaultKey: vaultKey, isQuery: true)

        let callable = Functions.functions(region: "us-central1").httpsCallable("searchKnowledge")
        let result = try await callable.call([
            "queryVector": cloaked.vector,
            "embeddingModelVersion": cloaked.modelVersion,
            "limit": max(1, min(limit, 50))
        ])
        guard let dict = result.data as? [String: Any],
              let rawHits = dict["hits"] as? [[String: Any]] else {
            throw DataVaultError.malformedResponse
        }
        let deviceId = await MainActor.run { MobileDeviceIdentity.loadOrCreateDeviceId() }
        let signalIdentity = try? OpenBurnBarSignalIdentityKeyStore().load(uid: uid, deviceId: deviceId)

        return rawHits.compactMap { raw -> PensieveMemoryHit? in
            Self.decodeHit(raw, uid: uid, vaultKey: vaultKey, signalIdentity: signalIdentity)
        }
    }

    static func decodeHit(
        _ raw: [String: Any],
        uid: String,
        vaultKey: Data,
        signalIdentity: OpenBurnBarSignalIdentityKeypair?
    ) -> PensieveMemoryHit? {
        let stableDocumentID = (raw["vectorId"] as? String) ?? (raw["chunkId"] as? String)
        let id = stableDocumentID ?? UUID().uuidString

        let signalText = stableDocumentID.flatMap { documentID -> String? in
            guard raw["signalEnvelope"] != nil else { return nil }
            do {
                guard let payload = try MobileCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    raw,
                    uid: uid,
                    collection: "cloud_search_knowledge",
                    docId: documentID,
                    field: "signalEnvelope",
                    bindingField: "sealedCiphertext",
                    signalIdentity: signalIdentity
                ) else {
                    return nil
                }
                return String(data: payload, encoding: .utf8)
            } catch {
                // Rollout compatibility: `searchKnowledge` returns legacy AES-GCM
                // `ciphertext` alongside the optional Signal envelope while Phase-E
                // remains flag-off. If the local Signal identity is missing or an
                // optional envelope is malformed, preserve legacy readability.
                return nil
            }
        }
        let legacyText = Self.decodeSealed(raw["ciphertext"]).flatMap {
            try? CloudVaultCrypto.openText($0, keyData: vaultKey)
        }
        guard let text = signalText ?? legacyText else { return nil }

        var sourcePath: String?
        var title: String?
        var category: String?
        if let sealedMetadata = Self.decodeSealed(raw["sealedMetadata"]),
           let metadataString = try? CloudVaultCrypto.openText(sealedMetadata, keyData: vaultKey),
           let metadata = try? JSONSerialization.jsonObject(with: Data(metadataString.utf8)) as? [String: Any] {
            sourcePath = metadata["source_path"] as? String
            title = metadata["page_title"] as? String
            category = metadata["category"] as? String
        }
        let score = (raw["score"] as? NSNumber)?.doubleValue ?? 0
        return PensieveMemoryHit(
            id: id,
            text: text,
            sourcePath: sourcePath,
            title: title,
            category: category,
            score: score
        )
    }

    private static func decodeSealed(_ raw: Any?) -> CloudVaultSealedText? {
        guard let dict = raw as? [String: Any],
              let algorithm = dict["algorithm"] as? String,
              let nonce = dict["nonce"] as? String,
              let ciphertext = dict["ciphertext"] as? String,
              let tag = dict["tag"] as? String else { return nil }
        let keyVersion = (dict["keyVersion"] as? NSNumber)?.intValue ?? CloudVaultCrypto.currentKeyVersion
        return CloudVaultSealedText(
            algorithm: algorithm,
            keyVersion: keyVersion,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
    }
}
