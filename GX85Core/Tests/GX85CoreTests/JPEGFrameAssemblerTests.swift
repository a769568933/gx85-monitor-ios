import Foundation
import XCTest
@testable import GX85Core

final class JPEGFrameAssemblerTests: XCTestCase {
    private let jpeg = Data([0xff, 0xd8, 0x11, 0x22, 0xff, 0xd9])

    func testExtractsJPEGWithPrefixAndSuffix() {
        var assembler = JPEGFrameAssembler()
        XCTAssertEqual(assembler.append(Data([1, 2, 3]) + jpeg + Data([4, 5]), now: 0), [jpeg])
        XCTAssertLessThanOrEqual(assembler.bufferedBytes, 1)
    }

    func testHandlesSOISplitAcrossPackets() {
        var assembler = JPEGFrameAssembler()
        XCTAssertEqual(assembler.append(Data([0, 0xff]), now: 0), [])
        XCTAssertEqual(assembler.append(Data([0xd8, 0x11, 0x22, 0xff]), now: 0.1), [])
        XCTAssertEqual(assembler.append(Data([0xd9]), now: 0.2), [jpeg])
    }

    func testIncompleteFrameExpires() {
        var assembler = JPEGFrameAssembler()
        _ = assembler.append(Data([0xff, 0xd8, 1]), now: 0)
        XCTAssertEqual(assembler.append(Data([2, 0xff, 0xd9]), now: 0.6), [])
        XCTAssertEqual(assembler.append(jpeg, now: 0.7), [jpeg])
    }

    func testOversizedFrameResynchronizes() {
        var assembler = JPEGFrameAssembler()
        _ = assembler.append(Data([0xff, 0xd8]) + Data(repeating: 1, count: 2 * 1024 * 1024), now: 0)
        XCTAssertLessThanOrEqual(assembler.bufferedBytes, 1)
        XCTAssertEqual(assembler.append(jpeg, now: 0.1), [jpeg])
        XCTAssertEqual(assembler.droppedFrames, 1)
    }

    func testDamagedFrameDoesNotPoisonNextFrame() {
        var assembler = JPEGFrameAssembler()
        XCTAssertEqual(assembler.append(Data([0xff, 0xd8, 1, 2]) + jpeg, now: 0), [jpeg])
        XCTAssertEqual(assembler.droppedFrames, 1)
    }

    func testMultipleFramesAndReset() {
        var assembler = JPEGFrameAssembler()
        XCTAssertEqual(assembler.append(jpeg + jpeg, now: 0), [jpeg, jpeg])
        _ = assembler.append(Data([0xff, 0xd8, 3]), now: 0.1)
        assembler.reset()
        XCTAssertEqual(assembler.append(Data([0xff, 0xd9]), now: 0.2), [])
    }
}
