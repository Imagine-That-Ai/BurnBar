import Foundation

/// Normalizes iroh NodeId strings for set membership checks.
public enum IrohNodeIdNormalization {
    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    public static func canonical(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Normalizes current 64-character hexadecimal and legacy 52-character
    /// unpadded base32 iroh NodeIds to the same 32-byte lowercase-hex form.
    public static func canonicalTransportNodeId(_ raw: String) -> String? {
        let normalized = canonical(raw)
        if normalized.count == 64,
           normalized.utf8.allSatisfy({ byte in
               (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
           }) {
            return normalized
        }
        guard normalized.utf8.count == 52 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var accumulator: UInt16 = 0
        var bitCount = 0
        for byte in normalized.utf8 {
            guard let index = base32Alphabet.firstIndex(of: byte) else { return nil }
            accumulator = (accumulator << 5) | UInt16(index)
            bitCount += 5
            while bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((accumulator >> UInt16(bitCount)) & 0xff))
                accumulator &= bitCount == 0 ? 0 : (1 << UInt16(bitCount)) - 1
            }
        }
        guard bytes.count == 32, accumulator == 0 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct IrohControllerRouteBinding: Sendable, Equatable {
    public let sourceDeviceId: String
    public let transportNodeId: String
    public let authorityPeerNodeId: String
    public let generation: UInt64
    public let registeredAtMillis: Int64
    public let expiresAtMillis: Int64

    public init?(
        sourceDeviceId: String,
        transportNodeId: String,
        authorityPeerNodeId: String,
        generation: UInt64,
        registeredAtMillis: Int64,
        expiresAtMillis: Int64
    ) {
        let sourceDeviceId = sourceDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorityPeerNodeId = authorityPeerNodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceDeviceId.isEmpty,
              sourceDeviceId.utf8.count <= 160,
              !authorityPeerNodeId.isEmpty,
              authorityPeerNodeId.utf8.count <= 160,
              let transportNodeId = IrohNodeIdNormalization.canonicalTransportNodeId(transportNodeId),
              generation > 0,
              registeredAtMillis > 0,
              expiresAtMillis > registeredAtMillis else {
            return nil
        }
        self.sourceDeviceId = sourceDeviceId
        self.transportNodeId = transportNodeId
        self.authorityPeerNodeId = authorityPeerNodeId
        self.generation = generation
        self.registeredAtMillis = registeredAtMillis
        self.expiresAtMillis = expiresAtMillis
    }

    public func isActive(atMillis: Int64) -> Bool {
        atMillis >= registeredAtMillis && atMillis < expiresAtMillis
    }
}

/// Inbound peer binding: hosts accept only server-verified, unexpired routes.
public struct IrohInboundPeerPolicy: Sendable, Equatable {
    private let legacyAllowedPeerNodeIds: Set<String>
    private let routeBindingsByTransportNodeId: [String: IrohControllerRouteBinding]

    public var allowedPeerNodeIds: Set<String> {
        legacyAllowedPeerNodeIds.union(routeBindingsByTransportNodeId.keys)
    }

    /// Compatibility initializer for loopback/media registries that do not
    /// carry server route metadata. Production controller admission uses the
    /// route-binding initializer below.
    public init(allowedPeerNodeIds: Set<String>) {
        legacyAllowedPeerNodeIds = Set(allowedPeerNodeIds.map(IrohNodeIdNormalization.canonical))
        routeBindingsByTransportNodeId = [:]
    }

    public init(routeBindings: [IrohControllerRouteBinding]) {
        legacyAllowedPeerNodeIds = []
        var bindings: [String: IrohControllerRouteBinding] = [:]
        var ambiguousNodeIds = Set<String>()
        for binding in routeBindings {
            if bindings[binding.transportNodeId] != nil {
                ambiguousNodeIds.insert(binding.transportNodeId)
            } else {
                bindings[binding.transportNodeId] = binding
            }
        }
        for nodeId in ambiguousNodeIds {
            bindings.removeValue(forKey: nodeId)
        }
        routeBindingsByTransportNodeId = bindings
    }

    public func binding(
        for remotePeerNodeId: String?,
        atMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> IrohControllerRouteBinding? {
        guard let remotePeerNodeId,
              let canonicalNodeId = IrohNodeIdNormalization.canonicalTransportNodeId(remotePeerNodeId),
              let binding = routeBindingsByTransportNodeId[canonicalNodeId],
              binding.isActive(atMillis: atMillis) else { return nil }
        return binding
    }

    public func allows(
        remotePeerNodeId: String?,
        atMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> Bool {
        if binding(for: remotePeerNodeId, atMillis: atMillis) != nil { return true }
        guard let remotePeerNodeId else { return false }
        return legacyAllowedPeerNodeIds.contains(IrohNodeIdNormalization.canonical(remotePeerNodeId))
    }
}
