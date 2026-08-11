import Foundation
import Testing
@testable import MeetGPT

@Suite("Connected team-source watcher")
struct TeamWatcherTests {
    private func item(_ seconds: TimeInterval, channel: String = "release",
                      text: String = "Falcon SLA") -> TeamItem {
        TeamItem(
            service: .slack, channel: channel, author: "qa",
            text: text, timestamp: Date(timeIntervalSince1970: seconds))
    }

    @Test("first scan establishes a high-water mark without replaying channel history")
    func firstScanIsAQuietBaseline() {
        let result = TeamWatcher.selectNewItems(
            [item(30), item(10), item(20)], after: nil)
        #expect(result.items.isEmpty)
        #expect(result.highWatermark == Date(timeIntervalSince1970: 30))
    }

    @Test("newest-first Slack pages deliver every unseen message in chronological order")
    func newestFirstDoesNotDropMessages() {
        let result = TeamWatcher.selectNewItems(
            [item(50), item(40), item(30), item(20)],
            after: Date(timeIntervalSince1970: 25))
        #expect(result.items.map(\.timestamp) == [30, 40, 50].map(Date.init(timeIntervalSince1970:)))
        #expect(result.highWatermark == Date(timeIntervalSince1970: 50))
    }

    @Test("duplicates and older messages cannot retrigger after the high-water mark")
    func oldAndDuplicateItemsStayConsumed() {
        let result = TeamWatcher.selectNewItems(
            [item(50), item(50), item(49), item(1)],
            after: Date(timeIntervalSince1970: 50))
        #expect(result.items.isEmpty)
        #expect(result.highWatermark == Date(timeIntervalSince1970: 50))
    }

    @Test("empty provider responses preserve the existing watermark")
    func emptyResponseDoesNotRewind() {
        let seen = Date(timeIntervalSince1970: 50)
        let result = TeamWatcher.selectNewItems([], after: seen)
        #expect(result.items.isEmpty)
        #expect(result.highWatermark == seen)
    }
}
