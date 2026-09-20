import Foundation

/// JSON payload inside `MediaFrame.Kind.bweFeedback`. Rides `media.stream.frame`
/// on `media.control` so phones can report RTT, loss, and NWPath constraint
/// without a Hermes wire-schema bump.
public struct MediaBweFeedbackPayload: Codable, Sendable, Equatable {
    public var roundTripMillis: Int
    public var packetLossRate: Double
    public var observedBitsPerSecond: Int
    public var pathConstrained: Bool

    public init(
        roundTripMillis: Int,
        packetLossRate: Double,
        observedBitsPerSecond: Int,
        pathConstrained: Bool
    ) {
        self.roundTripMillis = roundTripMillis
        self.packetLossRate = packetLossRate
        self.observedBitsPerSecond = observedBitsPerSecond
        self.pathConstrained = pathConstrained
    }

    public var sample: BitrateController.Sample {
        BitrateController.Sample(
            roundTripMillis: roundTripMillis,
            packetLossRate: packetLossRate,
            observedBitsPerSecond: observedBitsPerSecond,
            pathConstrained: pathConstrained
        )
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MediaBweFeedbackPayload {
        try JSONDecoder().decode(MediaBweFeedbackPayload.self, from: data)
    }

    public static func decodeIfPresent(from frame: MediaFrame) -> MediaBweFeedbackPayload? {
        guard frame.kind == .bweFeedback else { return nil }
        return try? decode(frame.payload)
    }

    /// NWPath / ConnectivityManager → constrained. Cellular, expensive, or
    /// explicitly constrained paths take the 250/500 kbps screen rungs.
    public static func isConstrainedPath(
        usesCellular: Bool,
        isExpensive: Bool,
        isConstrained: Bool
    ) -> Bool {
        usesCellular || isExpensive || isConstrained
    }
}
