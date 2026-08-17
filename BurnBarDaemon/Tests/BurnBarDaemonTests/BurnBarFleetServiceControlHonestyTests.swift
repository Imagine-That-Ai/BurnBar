@testable import BurnBarDaemon
import XCTest

final class BurnBarFleetServiceControlHonestyTests: XCTestCase {
    func test_orchestratorStateChecked_unwiredStoreThrowsInsteadOfNone() async {
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: 15,
            probes: [:]
        )
        let service = BurnBarFleetService(builder: builder)
        do {
            let state = try await service.orchestratorStateChecked()
            XCTFail("unwired control store must not return \(state.designation)")
        } catch let error as BurnBarFleetControlError {
            guard case .storeUnavailable = error else {
                return XCTFail("expected storeUnavailable, got \(error)")
            }
        } catch {
            XCTFail("expected BurnBarFleetControlError, got \(error)")
        }
    }
}
