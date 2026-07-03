#if !canImport(LibSignalClient)
import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarSignalCore

public enum OpenBurnBarSignalSessionTransportAvailability: Sendable {
    public static let isLibSignalBacked = false
    public static let unavailableReason = OpenBurnBarSignalCoreAvailability.unavailableReason
}
#endif
