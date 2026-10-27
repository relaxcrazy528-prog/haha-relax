import XCTest
import KeepOnlineCore
@testable import KeepOnlinePlatform

final class BackendInputTests: XCTestCase {
    func testInvalidNativeTimeoutsAreRejectedBeforeAnySystemRequest() {
        let backend = IOKitPowerBackend()
        for timeout in [0, -1, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try backend.create(kind: .systemIdle, timeout: timeout)) { error in
                XCTAssertEqual((error as? PowerBackendFailure)?.operation, .create)
            }
            XCTAssertThrowsError(try backend.renew(PowerToken(rawValue: 0), timeout: timeout)) { error in
                XCTAssertEqual((error as? PowerBackendFailure)?.operation, .renew)
            }
        }
    }
}
