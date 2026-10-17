import XCTest
import SwiftUI
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class CatPawMascotTests: XCTestCase {
    func testApprovedFivePosesAreBundledAndDistinct() throws {
        let states: [AgentStatus] = [.idle, .processing, .running, .waitingApproval, .waitingQuestion]
        let poses = states.map(CatPawView.poseName)
        XCTAssertEqual(Set(poses).count, 5)
        XCTAssertEqual(CatPawView.sprites.count, 5)
        var imageData = Set<Data>()
        for pose in poses {
            let image = try XCTUnwrap(CatPawView.sprites[pose])
            XCTAssertEqual(image.width, 40)
            XCTAssertEqual(image.height, 40)
            imageData.insert(try XCTUnwrap(image.dataProvider?.data) as Data)
        }
        XCTAssertEqual(imageData.count, 5)
    }

    func testBothCatPawRoutesRenderTheSameRoleAndClaudeKeepsItsOwn() throws {
        func frame(_ source: String) throws -> Data {
            let view = MascotView(source: source, status: .running, size: 80).routedContent
                .environment(\.mascotAnimationsActive, false)
                .environment(\.mascotStaticTime, 0)
                .frame(width: 80, height: 80)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        let ide = try frame("catpaw"), plugin = try frame("catpaw-idekit")
        XCTAssertEqual(ide, plugin)
        XCTAssertNotEqual(ide, try frame("claude"))
        for source in ["catpaw", "catpaw-idekit"] {
            var session = SessionSnapshot()
            session.source = source
            XCTAssertEqual(session.mascotSource, source)
        }
    }
}
