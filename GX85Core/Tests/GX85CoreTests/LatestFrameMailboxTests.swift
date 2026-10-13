import Foundation
import XCTest
@testable import GX85Core

final class LatestFrameMailboxTests: XCTestCase {
    func testMailboxKeepsOnlyNewestFrame() {
        var mailbox = LatestFrameMailbox()
        mailbox.offer(Data([1]))
        mailbox.offer(Data([2]))
        mailbox.offer(Data([3]))
        XCTAssertEqual(mailbox.take(), Data([3]))
        XCTAssertNil(mailbox.take())
    }

    func testResetDiscardsPendingFrame() {
        var mailbox = LatestFrameMailbox()
        mailbox.offer(Data([1]))
        mailbox.reset()
        XCTAssertNil(mailbox.take())
    }
}
