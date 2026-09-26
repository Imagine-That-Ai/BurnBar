import Foundation

/// Distinct Streams list states. Error must never render as empty.
public enum MobileStreamsListPresentation: String, Sendable, Equatable {
    case loading
    case failed
    case empty
    case locked
    case ready
    case paginating
}

public struct MobileStreamsPageOutcome: Sendable, Equatable {
    public let rowCount: Int
    public let hasMore: Bool
    public let canLoadNext: Bool
    public let presentation: MobileStreamsListPresentation

    public init(
        rowCount: Int,
        hasMore: Bool,
        canLoadNext: Bool,
        presentation: MobileStreamsListPresentation
    ) {
        self.rowCount = rowCount
        self.hasMore = hasMore
        self.canLoadNext = canLoadNext
        self.presentation = presentation
    }
}

/// Pagination / empty / error / lock for Streams. Source: iOS `ActivityStore`.
public enum MobileStreamsListPolicy {
    public static func presentation(
        isLoading: Bool,
        failed: Bool,
        isEmpty: Bool,
        entitled: Bool,
        hasMore: Bool,
        isPaginating: Bool,
        searchFailed: Bool
    ) -> MobileStreamsListPresentation {
        if !entitled { return .locked }
        if failed || searchFailed { return .failed }
        if isLoading && isEmpty { return .loading }
        if isEmpty { return .empty }
        if isPaginating && hasMore { return .paginating }
        return .ready
    }

    /// `hasMore` follows iOS: a present cursor means another page exists.
    public static func pageOutcome(
        accumulatedCount: Int,
        pageCount: Int,
        pageSize: Int,
        lastCursorPresent: Bool,
        failed: Bool,
        entitled: Bool = true,
        isLoading: Bool = false
    ) -> MobileStreamsPageOutcome {
        let hasMore = !failed && lastCursorPresent && pageCount == pageSize
        let presentation = presentation(
            isLoading: isLoading,
            failed: failed,
            isEmpty: accumulatedCount == 0,
            entitled: entitled,
            hasMore: hasMore,
            isPaginating: false,
            searchFailed: false
        )
        return MobileStreamsPageOutcome(
            rowCount: accumulatedCount,
            hasMore: hasMore,
            canLoadNext: hasMore && !isLoading && !failed,
            presentation: presentation
        )
    }
}
