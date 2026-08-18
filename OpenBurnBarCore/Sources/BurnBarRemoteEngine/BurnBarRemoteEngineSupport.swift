import Foundation

#if OPENBURNBAR_HAS_BURNBAR_REMOTE_FFI
@preconcurrency import BurnBarRemoteFFI
#endif

public struct BurnBarRemoteEngineReadiness: Equatable, Sendable {
    public let protocolVersion: String
    public let supportsIrohTransport: Bool
    public let supportsAdaptiveQuality: Bool
    public let supportsPermissionGate: Bool
    public let nativeBridgeAvailable: Bool

    public init(
        protocolVersion: String,
        supportsIrohTransport: Bool,
        supportsAdaptiveQuality: Bool,
        supportsPermissionGate: Bool,
        nativeBridgeAvailable: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.supportsIrohTransport = supportsIrohTransport
        self.supportsAdaptiveQuality = supportsAdaptiveQuality
        self.supportsPermissionGate = supportsPermissionGate
        self.nativeBridgeAvailable = nativeBridgeAvailable
    }
}

public struct BurnBarRemoteEngineDimensions: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32

    public init(width: UInt32, height: UInt32) throws {
        guard width > 0, height > 0 else {
            throw BurnBarRemoteEngineError.invalidDimensions(width: width, height: height)
        }
        self.width = width
        self.height = height
    }
}

public enum BurnBarRemoteEngineError: Error, Equatable, Sendable {
    case invalidDimensions(width: UInt32, height: UInt32)
}

public enum BurnBarRemoteEngineSupport {
    public static var isNativeBridgeAvailable: Bool {
        #if OPENBURNBAR_HAS_BURNBAR_REMOTE_FFI
        true
        #else
        false
        #endif
    }

    public static func readiness() -> BurnBarRemoteEngineReadiness {
        #if OPENBURNBAR_HAS_BURNBAR_REMOTE_FFI
        let readiness = BurnBarRemoteFFI.burnbarRemoteReadiness()
        return BurnBarRemoteEngineReadiness(
            protocolVersion: readiness.protocolVersion,
            supportsIrohTransport: readiness.supportsIrohTransport,
            supportsAdaptiveQuality: readiness.supportsAdaptiveQuality,
            supportsPermissionGate: readiness.supportsPermissionGate,
            nativeBridgeAvailable: true
        )
        #else
        return BurnBarRemoteEngineReadiness(
            protocolVersion: "burnbar-remote/v1",
            supportsIrohTransport: true,
            supportsAdaptiveQuality: true,
            supportsPermissionGate: true,
            nativeBridgeAvailable: false
        )
        #endif
    }

    public static func scaledDimensions(
        _ dimensions: BurnBarRemoteEngineDimensions,
        numerator: UInt32,
        denominator: UInt32
    ) throws -> BurnBarRemoteEngineDimensions {
        #if OPENBURNBAR_HAS_BURNBAR_REMOTE_FFI
        let scaled = try BurnBarRemoteFFI.remoteScaledDimensions(
            dimensions: BurnBarRemoteFFI.RemoteDimensions(width: dimensions.width, height: dimensions.height),
            numerator: numerator,
            denominator: denominator
        )
        return try BurnBarRemoteEngineDimensions(width: scaled.width, height: scaled.height)
        #else
        let divisor = UInt64(max(denominator, 1))
        let width = min(
            UInt64(UInt32.max),
            max(UInt64(1), UInt64(dimensions.width) * UInt64(numerator) / divisor)
        )
        let height = min(
            UInt64(UInt32.max),
            max(UInt64(1), UInt64(dimensions.height) * UInt64(numerator) / divisor)
        )
        return try BurnBarRemoteEngineDimensions(width: UInt32(width), height: UInt32(height))
        #endif
    }

    public static func modeRequiresInputPermission() -> Bool {
        #if OPENBURNBAR_HAS_BURNBAR_REMOTE_FFI
        return BurnBarRemoteFFI.remoteModeRequiresPermission(mode: .control, permission: .injectInput)
        #else
        return true
        #endif
    }
}
