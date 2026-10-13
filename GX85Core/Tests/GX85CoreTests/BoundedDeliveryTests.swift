import Foundation
import XCTest
@testable import GX85Core

final class BoundedDeliveryTests: XCTestCase {
    func testBlockedIngressKeepsOnlyBoundedNewestPackets() {
        let inbox = BoundedDatagramInbox(maxBytes: 8, maxPackets: 2)
        let generation = UUID()
        XCTAssertTrue(inbox.offer(Data([1, 1, 1, 1]), generation: generation))
        XCTAssertFalse(inbox.offer(Data([2, 2, 2, 2]), generation: generation))
        XCTAssertFalse(inbox.offer(Data([3, 3, 3, 3]), generation: generation))
        XCTAssertEqual(inbox.bufferedBytes, 8)
        let batch = inbox.takeBatch(limit: 4)
        XCTAssertEqual(batch.items.map(\.data), [Data([2, 2, 2, 2]), Data([3, 3, 3, 3])])
        XCTAssertEqual(batch.dropped, 1)
        XCTAssertFalse(inbox.needsAnotherDrain())
        XCTAssertTrue(inbox.offer(Data([4]), generation: generation))
    }

    func testIngressResetCannotMixOldGeneration() {
        let inbox = BoundedDatagramInbox()
        let old = UUID()
        let current = UUID()
        _ = inbox.offer(Data([1]), generation: old)
        inbox.reset()
        _ = inbox.offer(Data([2]), generation: current)
        XCTAssertEqual(inbox.takeBatch(limit: 4).items.map(\.generation), [current])
    }

    func testBlockedDeliveryCoalescesNewestValue() {
        let delivery = LatestValueSlot<Int>()
        XCTAssertTrue(delivery.offer(1))
        for value in 2...1000 { XCTAssertFalse(delivery.offer(value)) }
        XCTAssertEqual(delivery.take(), 1000)
        XCTAssertNil(delivery.take())
        XCTAssertTrue(delivery.offer(1001))
    }
}
