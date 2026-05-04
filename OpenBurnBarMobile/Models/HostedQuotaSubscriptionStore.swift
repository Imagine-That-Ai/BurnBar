import Foundation
import StoreKit

@Observable
@MainActor
final class HostedQuotaSubscriptionStore {
    static let productID = "com.burnbar.hostedQuotaSync.monthly"

    private let functions: FunctionsRepository

    private(set) var product: Product?
    private(set) var isActive = false
    private(set) var expirationDate: Date?
    private(set) var isLoading = false
    private(set) var error: String?

    init(functions: FunctionsRepository = .shared) {
        self.functions = functions
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            product = try await Product.products(for: [Self.productID]).first
            try await refreshEntitlement()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func purchase() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            if product == nil {
                product = try await Product.products(for: [Self.productID]).first
            }
            guard let product else {
                throw HostedQuotaSubscriptionError.productUnavailable
            }
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checked(verification)
                try await sync(transaction: transaction, signedTransactionJWS: verification.jwsRepresentation, active: true)
                await transaction.finish()
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshEntitlement() async throws {
        var matched: Transaction?
        var matchedJWS: String?
        for await result in Transaction.currentEntitlements {
            let transaction = try checked(result)
            guard transaction.productID == Self.productID else { continue }
            guard transaction.revocationDate == nil else { continue }
            if let expires = transaction.expirationDate, expires <= Date() { continue }
            matched = transaction
            matchedJWS = result.jwsRepresentation
            break
        }

        if let matched {
            try await sync(transaction: matched, signedTransactionJWS: matchedJWS, active: true)
        } else {
            isActive = false
            expirationDate = nil
            try await functions.syncHostedQuotaEntitlement(
                productID: Self.productID,
                transactionID: nil,
                originalTransactionID: nil,
                expiresAt: nil,
                signedTransactionJWS: nil,
                active: false
            )
        }
    }

    private func sync(transaction: Transaction, signedTransactionJWS: String?, active: Bool) async throws {
        isActive = active
        expirationDate = transaction.expirationDate
        try await functions.syncHostedQuotaEntitlement(
            productID: transaction.productID,
            transactionID: String(transaction.id),
            originalTransactionID: String(transaction.originalID),
            expiresAt: transaction.expirationDate,
            signedTransactionJWS: signedTransactionJWS,
            active: active
        )
    }

    private func checked<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }
}

enum HostedQuotaSubscriptionError: Error, LocalizedError {
    case productUnavailable

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return "Hosted Quota Sync is not available in the App Store configuration."
        }
    }
}
