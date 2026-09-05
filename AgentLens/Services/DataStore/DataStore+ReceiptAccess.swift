import Foundation
import OpenBurnBarKernel

/// Pass-through to `ReceiptStore` for durable receipt access, filtering, aggregates, and backfill.
extension DataStore {
    public func fetchReceipts(filter: ReceiptFilter, limit: Int = 200, offset: Int = 0) async throws -> [ReceiptRecord] {
        try await actor.receiptStore.fetchReceipts(filter: filter, limit: limit, offset: offset)
    }

    public func fetchReceipt(id: String) async throws -> ReceiptRecord? {
        try await actor.receiptStore.fetchReceipt(id: id)
    }

    public func fetchReceiptForSession(sessionId: String) async throws -> ReceiptRecord? {
        try await actor.receiptStore.fetchReceiptForSession(sessionId: sessionId)
    }

    public func insertReceipt(_ receipt: ReceiptRecord) async throws {
        try await actor.receiptStore.insert(receipt: receipt)
    }

    public func setReceiptStarred(receiptId: String, isStarred: Bool) async throws {
        try await actor.receiptStore.setStarred(receiptId: receiptId, isStarred: isStarred)
    }

    public func updateReceiptQualityReview(receiptId: String, review: ReceiptQualityReview) async throws {
        try await actor.receiptStore.updateQualityReview(receiptId: receiptId, review: review)
    }

    public func calculateReceiptAggregateSummary(filter: ReceiptFilter) async throws -> ReceiptAggregateSummary {
        try await actor.receiptStore.calculateAggregateSummary(filter: filter)
    }

    @discardableResult
    public func backfillReceiptsFromConversations() async throws -> Int {
        try await actor.receiptStore.backfillReceiptsFromConversations()
    }
}
