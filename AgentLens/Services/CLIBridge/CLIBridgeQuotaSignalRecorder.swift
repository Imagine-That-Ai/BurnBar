import Foundation
import OpenBurnBarCore

final class CLIBridgeQuotaSignalRecorder: Sendable {
    private let state = Locked<String?>(nil)

    func record(_ detail: String) {
        state.withLock { current in
            if current == nil { current = detail }
        }
    }

    func snapshot() -> String? {
        state.read()
    }
}
