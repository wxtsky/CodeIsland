import XCTest
import CodeIslandCore
@testable import CodeIsland

final class MascotViewTests: XCTestCase {
    func testSilentWorkModeKeepsWorkingMascotStill() {
        XCTAssertEqual(effectiveMascotStatus(.running, silentWorkMode: true), .idle)
        XCTAssertEqual(effectiveMascotStatus(.processing, silentWorkMode: true), .idle)
    }

    func testSilentWorkModePreservesActionableStates() {
        XCTAssertEqual(effectiveMascotStatus(.waitingApproval, silentWorkMode: true), .waitingApproval)
        XCTAssertEqual(effectiveMascotStatus(.waitingQuestion, silentWorkMode: true), .waitingQuestion)
        XCTAssertEqual(effectiveMascotStatus(.idle, silentWorkMode: true), .idle)
    }

    func testDisabledSilentWorkModeLeavesStatusUntouched() {
        XCTAssertEqual(effectiveMascotStatus(.processing, silentWorkMode: false), .processing)
        XCTAssertEqual(effectiveMascotStatus(.running, silentWorkMode: false), .running)
    }
}
