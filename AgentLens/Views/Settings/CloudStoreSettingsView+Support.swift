@preconcurrency import SwiftUI
import AppKit
import StoreKit
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import FirebaseFunctions
import OpenBurnBarCore

// Aurora card/button styles, Mac pricing tiers + purchase store, and remote-MCP client store/sections.
// Extracted from CloudStoreSettingsView.swift (god-file decomposition) — same module, verbatim.

//
// Single chrome primitive used everywhere on this pane. UltraThinMaterial
// + warm `cardGradient` overlay + ember-tinted hairline. Replaces the old
// `MercuryFoilCard`.
struct AuroraGlassCardMac<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DesignSystem.Colors.cardGradient)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.30),
                                DesignSystem.Colors.border.opacity(0.50),
                                DesignSystem.Colors.blaze.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.10), radius: 14, y: 6)
    }
}

//
// Ember→amber gradient capsule with a thin amber hairline + ember-tinted
// drop shadow. Drop-in replacement for the iOS `.aurora(.primary)` style.
struct AuroraPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.primaryGradient)
                    .opacity(configuration.isPressed ? 0.90 : 1.0)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.amber.opacity(0.55), lineWidth: 1.0)
            )
            .shadow(
                color: DesignSystem.Colors.ember.opacity(0.30),
                radius: configuration.isPressed ? 6 : 12,
                y: configuration.isPressed ? 2 : 6
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// Quieter sibling — `.ultraThinMaterial` capsule with a thin border. For
/// "Change badge" / "Restore" affordances next to a primary CTA.
struct AuroraSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.65), lineWidth: 0.6)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

//
// Static, honest copy for each of the four marketing tiers, mirrored 1:1 with
// website/src/pages/pricing.astro + site.ts. Prices are NOT stored here — the
// live `Product.displayPrice` from StoreKit drives the numbers; this model only
// carries names, summaries, feature bullets, crest asset names, and the per-tier
// holographic palette.
struct MacPricingTierModel: Identifiable {
    struct IncludedNote {
        let label: String
        let lines: [String]
    }

    let tier: MacCloudPricingTier
    let eyebrow: String
    let name: String
    let summary: String
    let bullets: [String]
    let includedNote: IncludedNote?
    /// Asset-catalog imageset for the transparent crest. `nil` for Local (bare).
    let crestAsset: String?
    let accent: Color
    /// Iridescent gradient stops for the holographic silhouette (mirrors the
    /// website's per-tier `--holo-grad`).
    let holoPalette: [Color]
    let ctaVerb: String
    let highlightBadge: String?

    var id: String { tier.rawValue }
    var entitlementTier: MacCloudTier { tier.entitlementTier }

    static let all: [MacPricingTierModel] = [
        MacPricingTierModel(
            tier: .local,
            eyebrow: "FREE · LOCAL",
            name: "OpenBurnBar Local",
            summary: "Local-first cost & quota tracking. No account. No cloud.",
            bullets: [
                "Local SQLite tracking, zero telemetry",
                "Cost & token rollups — today / week / month / all-time",
                "Quota windows for every connected provider",
                "Daemon, CLI, and editor panels",
                "Hermes assistant on local backends"
            ],
            includedNote: nil,
            crestAsset: nil,
            accent: DesignSystem.Colors.textSecondary,
            holoPalette: [],
            ctaVerb: "",
            highlightBadge: nil
        ),
        MacPricingTierModel(
            tier: .cloud,
            eyebrow: "OPENBURNBAR CLOUD",
            name: "BurnBar Cloud",
            summary: "Sync your quota, encrypted history, and agent memory across devices.",
            bullets: [
                "Hosted quota refresh from any signed-in device",
                "Conversation backup & resume across iPhone, iPad & Mac",
                "Encrypted session history, searchable everywhere",
                "Agent memory sync across every device",
                "Verified entitlement — checked server-side"
            ],
            includedNote: MacPricingTierModel.IncludedNote(
                label: "Included",
                lines: [
                    "Everything in Local, local-first",
                    "Any eligible introductory offer is shown by Apple before purchase"
                ]
            ),
            crestAsset: "CloudTierCrest",
            accent: DesignSystem.Colors.ember,
            // Warm ember iridescence.
            holoPalette: [
                Color(hex: "FFD56B"),
                Color(hex: "FF8A3D"),
                Color(hex: "FF5C8A"),
                Color(hex: "B06BFF")
            ],
            ctaVerb: "Subscribe to",
            highlightBadge: "Most popular"
        ),
        MacPricingTierModel(
            tier: .pro,
            eyebrow: "FOR POWER USERS",
            name: "BurnBar Cloud Pro",
            summary: "Use your Mac from your phone and let agents work under your grant.",
            bullets: [
                "Everything in BurnBar Cloud",
                "Floo — see & use your Mac from your phone",
                "Agent Control — agents work under your grant",
                "Live screen, files, calls & shared clipboard",
                "Tamper-proof action record · per-task grants"
            ],
            includedNote: MacPricingTierModel.IncludedNote(
                label: "Included each month",
                lines: [
                    "500 hosted Agent Control actions",
                    "50 relay-accounting GB",
                    "Prepaid overage only · BYOK never spends credits"
                ]
            ),
            crestAsset: "CloudTierCrestPro",
            accent: DesignSystem.Colors.whimsy,
            // Cool aqua iridescence.
            holoPalette: [
                Color(hex: "5EF0C9"),
                Color(hex: "38D6F3"),
                Color(hex: "4F8BFF"),
                Color(hex: "8EF0A8")
            ],
            ctaVerb: "Subscribe to",
            highlightBadge: nil
        ),
        MacPricingTierModel(
            tier: .ultra,
            eyebrow: "YOUR WHOLE SECOND BRAIN",
            name: "BurnBar Cloud Ultra",
            summary: "Everything in Cloud Pro, plus 10× agent memory.",
            bullets: [
                "Everything in BurnBar Cloud Pro",
                "10× agent memory: 100 sources · 500,000 chunks · 10 GB",
                "Sealed on-device — search runs over encrypted structures (some patterns stay visible)",
                "Same hosted Agent Control & relay allowance as Pro"
            ],
            includedNote: MacPricingTierModel.IncludedNote(
                label: "Private semantic memory",
                lines: [
                    "Cloaked vectors + sealed text — hosted recall is opt-in; structural patterns remain visible",
                    "500 hosted actions · 50 relay-accounting GB each month",
                    "Prepaid overage only · BYOK never spends credits"
                ]
            ),
            crestAsset: "CloudTierCrestUltra",
            accent: DesignSystem.Colors.amber,
            // Full-spectrum premium iridescence.
            holoPalette: [
                Color(hex: "FFD56B"),
                Color(hex: "7DD3FC"),
                Color(hex: "C084FC"),
                Color(hex: "5EEAD4"),
                Color(hex: "FF9EC7")
            ],
            ctaVerb: "Subscribe to",
            highlightBadge: "Top tier"
        )
    ]
}

//
// The signature look: each paid tier's transparent crest is used as a silhouette
// MASK over an iridescent gradient, rendered very faint behind the card content
// so every line of copy stays legible. A slow, tasteful angular shimmer sweeps
// the gradient — disabled entirely under Reduce Motion (a still, even fainter
// ghost remains). This is the native SwiftUI mirror of the website's
// `.plan__holo` masked-silhouette technique.
struct TierHolographicAccent: View {
    let crestAsset: String
    let palette: [Color]
    let reduceMotion: Bool

    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let side = min(max(geo.size.width, geo.size.height) * 0.92, 360)
            iridescentGradient
                .frame(width: side, height: side)
                .mask(
                    Image(crestAsset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: side, height: side)
                )
                .opacity(reduceMotion ? 0.08 : 0.13)
                .blur(radius: 0.5)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                .offset(x: geo.size.width * 0.18, y: -geo.size.height * 0.04)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 11).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }

    private var iridescentGradient: some View {
        // A wide, looped gradient sweep so the iridescence drifts across the
        // silhouette without a visible seam. Falls back gracefully for short
        // palettes.
        let stops = palette.isEmpty ? [Color.white.opacity(0.4)] : palette
        let looped = stops + stops.reversed() + [stops.first ?? .white]
        return AngularGradient(
            gradient: Gradient(colors: looped),
            center: .center,
            angle: .degrees(reduceMotion ? 0 : Double(phase) * 360)
        )
        .saturation(1.2)
    }
}

/// The four marketing tiers mirrored on the macOS pricing pane. `local` is the
/// free, account-less product; the other three are App Store subscriptions whose
/// live price comes from StoreKit (`displayPrice`).
enum MacCloudBillingPeriod: String, CaseIterable, Identifiable {
    case monthly
    case annual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly: return "Monthly"
        case .annual: return "Annual"
        }
    }

    var priceSuffix: String {
        switch self {
        case .monthly: return "/ month"
        case .annual: return "/ year"
        }
    }
}

enum MacCloudPricingTier: String, CaseIterable, Identifiable {
    case local
    case cloud
    case pro
    case ultra

    var id: String { rawValue }

    /// The monthly StoreKit product purchased for this tier. `nil` for Local.
    /// These match `OpenBurnBarProductCatalog` (iOS) and the server config IDs.
    var monthlyProductID: String? {
        switch self {
        case .local: return nil
        case .cloud:  return MacCloudStoreKitProductCatalog.cloudMonthlyProductID
        case .pro:    return MacCloudStoreKitProductCatalog.cloudProMonthlyProductID
        case .ultra:  return MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID
        }
    }

    var annualProductID: String? {
        switch self {
        case .local: return nil
        case .cloud:  return MacCloudStoreKitProductCatalog.cloudAnnualProductID
        case .pro:    return MacCloudStoreKitProductCatalog.cloudProAnnualProductID
        case .ultra:  return MacCloudStoreKitProductCatalog.cloudUltraAnnualProductID
        }
    }

    func productID(for billingPeriod: MacCloudBillingPeriod) -> String? {
        switch billingPeriod {
        case .monthly: return monthlyProductID
        case .annual: return annualProductID
        }
    }

    /// The entitlement tier this purchase resolves to once the server reconciles.
    var entitlementTier: MacCloudTier {
        switch self {
        case .local: return .free
        case .cloud:  return .cloud
        case .pro:    return .pro
        case .ultra:  return .ultra
        }
    }
}

struct MacHostedQuotaCurrentEntitlement: Equatable {
    let productID: String
    let signedTransactionJWS: String
    let expirationDate: Date?
    let purchaseDate: Date?
    let transactionID: UInt64?
}

@MainActor
final class MacHostedQuotaPurchaseStore: ObservableObject {
    static let productID = MacCloudStoreKitProductCatalog.cloudMonthlyProductID

    /// Monthly and annual subscription products for every paid tier. The
    /// selected cadence always resolves to a real StoreKit product; annual
    /// pricing is never a decorative fallback beside a monthly purchase.
    static let tierProductIDs: [MacCloudPricingTier: [MacCloudBillingPeriod: String]] = {
        var map: [MacCloudPricingTier: [MacCloudBillingPeriod: String]] = [:]
        for tier in MacCloudPricingTier.allCases {
            var products: [MacCloudBillingPeriod: String] = [:]
            for period in MacCloudBillingPeriod.allCases {
                if let id = tier.productID(for: period) {
                    products[period] = id
                }
            }
            if !products.isEmpty {
                map[tier] = products
            }
        }
        return map
    }()

    /// Documented expected price per tier — used only as fallback copy until the
    /// live `Product.displayPrice` arrives. Never the source of truth for a sale.
    static let fallbackMonthlyPrice: [MacCloudPricingTier: String] = [
        .cloud: "$7.99",
        .pro: "$24.99",
        .ultra: "$59.99"
    ]
    static let fallbackAnnualPrice: [MacCloudPricingTier: String] = [
        .cloud: "$79",
        .pro: "$249",
        .ultra: "$599"
    ]

    static let entitlementProductIDs = MacCloudStoreKitProductCatalog.entitlementProductIDs

    /// The primary (Cloud) product, kept for the legacy single-tier call sites.
    @Published private(set) var product: Product?
    /// Live StoreKit products keyed by product id, covering all six paid
    /// tier/cadence combinations.
    @Published private(set) var productsByID: [String: Product] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    /// The exact StoreKit product whose purchase sheet is currently opening.
    @Published private(set) var purchasingProductID: String?
    @Published private(set) var error: String?

    private var transactionUpdatesTask: Task<Void, Never>?

    deinit {
        transactionUpdatesTask?.cancel()
    }

    func load() async {
        startObservingTransactionUpdates()
        await loadProductMetadata()
    }

    /// Live `displayPrice` for a tier and cadence, or the documented fallback
    /// while the App Store catalogue is still loading.
    func displayPrice(
        for tier: MacCloudPricingTier,
        billingPeriod: MacCloudBillingPeriod
    ) -> String? {
        guard let productID = tier.productID(for: billingPeriod) else { return nil }
        if let product = productsByID[productID] {
            return product.displayPrice // cov:ignore -- needs a live App Store catalogue entry; the per-cadence fallback paths below are unit-tested
        }
        switch billingPeriod {
        case .monthly: return Self.fallbackMonthlyPrice[tier]
        case .annual: return Self.fallbackAnnualPrice[tier]
        }
    }

    func purchase() async {
        await purchase(tier: .cloud, billingPeriod: .monthly)
    }

    func purchase(
        tier: MacCloudPricingTier,
        billingPeriod: MacCloudBillingPeriod = .monthly
    ) async {
        guard let productID = tier.productID(for: billingPeriod) else { return }
        guard !isPurchasing else { return }
        isPurchasing = true
        purchasingProductID = productID
        error = nil
        defer {
            isPurchasing = false
            purchasingProductID = nil
        }

        do {
            guard FirebaseApp.app() != nil else {
                throw MacHostedQuotaPurchaseError.cloudUnavailable
            }
            // cov:ignore-start -- resolves the live StoreKit purchase target; unreachable in unit tests, which fail closed on the FirebaseApp guard above
            var purchaseTarget = productsByID[productID]
            if purchaseTarget == nil {
                purchaseTarget = try await Product.products(for: [productID]).first
                if let purchaseTarget {
                    productsByID[productID] = purchaseTarget
                }
            }
            // cov:ignore-end
            guard let purchaseTarget else {
                throw MacHostedQuotaPurchaseError.productUnavailable
            }

            let signedInUser = Auth.auth().currentUser.flatMap { $0.isAnonymous ? nil : $0 }
            guard let signedInUser else {
                throw MacHostedQuotaPurchaseError.signedOutSubscriptionPurchase
            }
            let appAccountToken = try await mintAppAccountToken(productID: productID)
            MacStoreKitAppAccountTokenBindingStore.shared.record(
                appAccountToken: appAccountToken,
                uid: signedInUser.uid,
                productID: productID
            )
            let purchaseOptions: Set<Product.PurchaseOption> = [
                .appAccountToken(appAccountToken)
            ]

            let result = try await purchaseTarget.purchase(options: purchaseOptions)
            switch result {
            case .success(let verification):
                let transaction = try checked(verification)
                try await verifyHostedQuotaEntitlement(
                    signedTransactionJWS: verification.jwsRepresentation,
                    productID: transaction.productID
                )
                await transaction.finish()
            case .pending:
                error = "Apple is still processing this purchase. OpenBurnBar will update when the transaction completes."
            case .userCancelled:
                break
            @unknown default:
                error = "Apple returned an unknown purchase state. Try Restore Purchases after the App Store finishes processing."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restorePurchases() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            guard FirebaseApp.app() != nil else {
                error = MacHostedQuotaPurchaseError.cloudUnavailable.localizedDescription
                return
            }
            try await AppStore.sync()
            guard Auth.auth().currentUser?.isAnonymous == false else {
                error = "Sign in to OpenBurnBar before restoring purchases so Apple can link OpenBurnBar Cloud to your account."
                return
            }

            if let entitlement = await findCurrentEntitlement() {
                try await restoreHostedQuotaEntitlement(
                    productID: entitlement.productID,
                    signedTransactionJWS: entitlement.signedTransactionJWS // cov:ignore -- needs a live verified StoreKit entitlement; the selection policy is unit-tested via preferredCurrentEntitlement(from:)
                )
            } else {
                try await restoreHostedQuotaEntitlement(
                    productID: Self.productID,
                    signedTransactionJWS: nil
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadProductMetadata() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // cov:ignore-start -- fetches the live App Store catalogue; the tier/cadence id mapping is locked by testMacCloudPricingTierMapsEveryPaidMonthlyAndAnnualProduct
            let ids = Array(Set(Self.tierProductIDs.values.flatMap(\.values)))
            let products = try await Product.products(for: ids)
            productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            product = productsByID[Self.productID]
            // cov:ignore-end
        } catch {
            if self.error == nil {
                self.error = error.localizedDescription
            }
        }
    }

    private func startObservingTransactionUpdates() {
        guard transactionUpdatesTask == nil else { return }
        transactionUpdatesTask = Task.detached { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.handle(transactionUpdate: update)
            }
        }
    }

    private func handle(transactionUpdate update: VerificationResult<StoreKit.Transaction>) async {
        do {
            let transaction = try checked(update)
            guard Self.entitlementProductIDs.contains(transaction.productID) else { return }
            guard FirebaseApp.app() != nil else { return }
            guard Auth.auth().currentUser?.isAnonymous == false else { return }
            try await verifyHostedQuotaEntitlement(
                signedTransactionJWS: update.jwsRepresentation,
                productID: transaction.productID
            )
            await transaction.finish()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // cov:ignore-start -- iterates the live StoreKit entitlement sequence, which unit tests cannot seed; the selection policy is unit-tested via preferredCurrentEntitlement(from:)
    private func findCurrentEntitlement() async -> MacHostedQuotaCurrentEntitlement? {
        var entitlements: [MacHostedQuotaCurrentEntitlement] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            do {
                let transaction = try checked(result)
                guard Self.entitlementProductIDs.contains(transaction.productID) else { continue }
                guard transaction.revocationDate == nil else { continue }
                if let expirationDate = transaction.expirationDate, expirationDate <= Date() {
                    continue
                }
                entitlements.append(
                    MacHostedQuotaCurrentEntitlement(
                        productID: transaction.productID,
                        signedTransactionJWS: result.jwsRepresentation,
                        expirationDate: transaction.expirationDate,
                        purchaseDate: transaction.originalPurchaseDate,
                        transactionID: transaction.id
                    )
                )
            } catch {
                continue
            }
        }
        return Self.preferredCurrentEntitlement(from: entitlements)
    }
    // cov:ignore-end

    static func preferredCurrentEntitlement(
        from entitlements: [MacHostedQuotaCurrentEntitlement]
    ) -> MacHostedQuotaCurrentEntitlement? {
        entitlements
            .filter { entitlementProductIDs.contains($0.productID) }
            .max { lhs, rhs in
                let lhsTier = MacCloudStoreKitProductCatalog.tier(for: lhs.productID)?.rawValue ?? 0
                let rhsTier = MacCloudStoreKitProductCatalog.tier(for: rhs.productID)?.rawValue ?? 0
                if lhsTier != rhsTier { return lhsTier < rhsTier }

                let lhsExpiration = lhs.expirationDate ?? .distantFuture
                let rhsExpiration = rhs.expirationDate ?? .distantFuture
                if lhsExpiration != rhsExpiration { return lhsExpiration < rhsExpiration }

                let lhsPurchase = lhs.purchaseDate ?? .distantPast
                let rhsPurchase = rhs.purchaseDate ?? .distantPast
                if lhsPurchase != rhsPurchase { return lhsPurchase < rhsPurchase }

                let lhsTransactionID = lhs.transactionID ?? 0
                let rhsTransactionID = rhs.transactionID ?? 0
                if lhsTransactionID != rhsTransactionID {
                    return lhsTransactionID < rhsTransactionID
                }
                return lhs.productID < rhs.productID
            }
    }

    private func mintAppAccountToken(productID: String = MacHostedQuotaPurchaseStore.productID) async throws -> UUID {
        let functions = try hostedQuotaFunctions()
        let result = try await functions.httpsCallable("beginEntitlementBinding").call([
            "productID": productID,
            "clientPlatform": "macos"
        ])
        guard
            let dict = result.data as? [String: Any],
            let rawToken = dict["appAccountToken"] as? String,
            let token = UUID(uuidString: rawToken)
        else {
            throw MacHostedQuotaPurchaseError.invalidBindingToken
        }
        return token
    }

    private func verifyHostedQuotaEntitlement(
        signedTransactionJWS: String,
        productID: String
    ) async throws {
        let functions = try hostedQuotaFunctions()
        _ = try await functions.httpsCallable("verifyHostedQuotaEntitlement").call([
            "signedTransactionJWS": signedTransactionJWS,
            "productID": productID
        ])
    }

    private func restoreHostedQuotaEntitlement(
        productID: String,
        signedTransactionJWS: String?
    ) async throws {
        var payload: [String: Any] = ["productID": productID]
        if let signedTransactionJWS, !signedTransactionJWS.isEmpty {
            payload["signedTransactionJWS"] = signedTransactionJWS
        }
        let functions = try hostedQuotaFunctions()
        _ = try await functions.httpsCallable("restoreHostedQuotaEntitlement").call(payload)
    }

    private func hostedQuotaFunctions() throws -> Functions {
        guard FirebaseApp.app() != nil else {
            throw MacHostedQuotaPurchaseError.cloudUnavailable
        }
        return Functions.functions(region: "us-central1")
    }

    private func checked<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }
}

enum MacHostedQuotaPurchaseError: LocalizedError {
    case cloudUnavailable
    case productUnavailable
    case invalidBindingToken
    case signedOutSubscriptionPurchase

    var errorDescription: String? {
        switch self {
        case .cloudUnavailable:
            return "OpenBurnBar Cloud is not configured on this Mac."
        case .productUnavailable:
            return "OpenBurnBar Cloud is not available from the App Store yet. Try again in a moment."
        case .invalidBindingToken:
            return "OpenBurnBar could not prepare the Apple purchase token. Sign in again and retry."
        case .signedOutSubscriptionPurchase:
            return "Sign in to OpenBurnBar before subscribing so Apple can link OpenBurnBar Cloud to your account."
        }
    }
}

//
// The Firestore-backed model + listener for connected MCP clients. Chrome
// underneath has switched to Aurora glass; the rest of the structure is
// untouched.
struct MacRemoteMCPClientRecord: Identifiable, Hashable {
    let id: String
    let displayName: String
    let clientType: String
    let allowedScopes: [String]
    let grantMode: String
    let createdAt: Date?
    let lastUsedAt: Date?
    let revokedAt: Date?

    var isRevoked: Bool { revokedAt != nil }

    var displayType: String {
        clientType.isEmpty ? "generic MCP" : clientType
    }

    var scopeSummary: String {
        allowedScopes.isEmpty ? "No scopes recorded" : allowedScopes.sorted().joined(separator: ", ")
    }

    var modeSummary: String {
        switch grantMode {
        case "sealed_only": return "Sealed only"
        case "local_decrypt_shim": return "Local decrypt shim"
        case "remote_readable_explicit_opt_in": return "Remote readable opt-in"
        default: return grantMode.isEmpty ? "Local decrypt shim" : grantMode.replacingOccurrences(of: "_", with: " ")
        }
    }

    var activitySummary: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        if let lastUsedAt {
            return "Used \(formatter.localizedString(for: lastUsedAt, relativeTo: Date()))"
        }
        if let createdAt {
            return "Added \(formatter.localizedString(for: createdAt, relativeTo: Date()))"
        }
        return "Awaiting first use"
    }
}

@MainActor
final class MacRemoteMCPClientStore: ObservableObject {
    @Published private(set) var clients: [MacRemoteMCPClientRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var revokingClientID: String?

    private nonisolated(unsafe) var listener: ListenerRegistration?
    private nonisolated(unsafe) var authHandle: AuthStateDidChangeListenerHandle?

    deinit {
        listener?.remove()
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
    }

    func startListening() {
        guard FirebaseApp.app() != nil else {
            clients = []
            error = "Cloud is not configured on this Mac."
            return
        }

        if authHandle == nil {
            authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
                Task { @MainActor in
                    self?.restartListener(uid: user?.uid)
                }
            }
        }

        restartListener(uid: Auth.auth().currentUser?.uid)
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        isLoading = false
    }

    func revoke(_ client: MacRemoteMCPClientRecord) async {
        guard !client.isRevoked else { return }
        revokingClientID = client.id
        error = nil
        do {
            let deviceId = ComputerUseSecurityCallableClient.loadOrCreateLocalDeviceId()
            _ = try await ComputerUseSecurityCallableClient.callHighRiskOwnerAction(
                "revokeRemoteMcpClient",
                deviceId: deviceId,
                actionKind: "remote_mcp_grant_revoke",
                subjectId: client.id,
                payload: ["clientId": client.id]
            )
        } catch {
            self.error = error.localizedDescription
        }
        revokingClientID = nil
    }

    private func restartListener(uid: String?) {
        listener?.remove()
        listener = nil
        error = nil
        guard let uid else {
            clients = []
            isLoading = false
            error = "Sign in to view connected MCP clients."
            return
        }

        isLoading = true
        listener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("remote_mcp_clients")
            .order(by: "updatedAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isLoading = false
                    if let error {
                        self.clients = []
                        self.error = error.localizedDescription
                        return
                    }
                    self.clients = (snapshot?.documents ?? [])
                        .compactMap { Self.decode(documentID: $0.documentID, data: $0.data()) }
                        .sorted { lhs, rhs in
                            (lhs.lastUsedAt ?? lhs.createdAt ?? .distantPast) > (rhs.lastUsedAt ?? rhs.createdAt ?? .distantPast)
                        }
                }
            }
    }

    private static func decode(documentID: String, data: [String: Any]) -> MacRemoteMCPClientRecord {
        let clientID = (data["clientId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (data["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientType = (data["clientType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = data["allowedScopes"] as? [String] ?? []
        let grantMode = (data["grantMode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return MacRemoteMCPClientRecord(
            id: clientID?.isEmpty == false ? clientID! : documentID,
            displayName: displayName?.isEmpty == false ? displayName! : "OpenBurnBar MCP client",
            clientType: clientType ?? "",
            allowedScopes: scopes,
            grantMode: grantMode ?? "local_decrypt_shim",
            createdAt: date(from: data["createdAt"]),
            lastUsedAt: date(from: data["lastUsedAt"]),
            revokedAt: date(from: data["revokedAt"])
        )
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }
}

struct MacRemoteMCPConnectedClientsSection: View {
    @ObservedObject var store: MacRemoteMCPClientStore
    @State private var pendingRevoke: MacRemoteMCPClientRecord?
    @State private var isConfirmingRevoke = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Connected clients", systemImage: "rectangle.connected.to.line.below")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.clients.isEmpty && !store.isLoading {
                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("No MCP clients are connected yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            } else {
                ForEach(store.clients) { client in
                    MacRemoteMCPClientRow(
                        client: client,
                        isRevoking: store.revokingClientID == client.id,
                        onRevoke: {
                            pendingRevoke = client
                            isConfirmingRevoke = true
                        }
                    )
                }
            }
        }
        .confirmationDialog("Revoke MCP client?", isPresented: $isConfirmingRevoke, titleVisibility: .visible) {
            if let pendingRevoke {
                Button("Revoke \(pendingRevoke.displayName)", role: .destructive) {
                    Task { await store.revoke(pendingRevoke) }
                }
            }
        } message: {
            if let pendingRevoke {
                Text("This immediately blocks \(pendingRevoke.displayName) and revokes its outstanding grants.")
            }
        }
    }
}

struct MacRemoteMCPClientRow: View {
    let client: MacRemoteMCPClientRecord
    let isRevoking: Bool
    let onRevoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: client.isRevoked ? "xmark.seal.fill" : "checkmark.seal.fill")
                    .foregroundStyle(client.isRevoked ? DesignSystem.Colors.textMuted : DesignSystem.Colors.success)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(client.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(client.displayType) · \(client.modeSummary)")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(client.scopeSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if client.isRevoked {
                    Text("Revoked")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    Button(action: onRevoke) {
                        Group {
                            if isRevoking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.error.opacity(0.88))
                    .disabled(isRevoking)
                    .accessibilityLabel("Revoke \(client.displayName)")
                }
            }

            Text(client.activitySummary)
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    client.isRevoked
                        ? AnyShapeStyle(DesignSystem.Colors.border.opacity(0.50))
                        : AnyShapeStyle(DesignSystem.Colors.ember.opacity(0.30)),
                    lineWidth: 0.6
                )
        )
    }
}
