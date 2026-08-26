// Unit tests for the snapshot App Intents read.
//
// These exist because the snapshot is the only thing an out-of-process intent can see.
// A wrong value here is not a visible failure — Shortcuts just answers confidently and
// incorrectly. The partial-update semantics are the risky part: callers learn different
// fields at different times, and an over-eager write silently erases what the other knew.
//
// The 0/0 case below is not hypothetical. It shipped: peer counts were written only by
// the peer-list view, so "Count Online Devices" answered 0 until that screen had been
// opened. Caught on device, fixed by seeding counts at connect.

@testable import Tunnelless_iOS
import XCTest

final class TailnetSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TailnetSnapshotStore.clear()
    }

    override func tearDown() {
        TailnetSnapshotStore.clear()
        super.tearDown()
    }

    func testEmptyBeforeAnythingIsWritten() {
        let s = TailnetSnapshotStore.load()
        XCTAssertFalse(s.isConnected)
        XCTAssertEqual(s.peerCount, 0)
        XCTAssertEqual(s.updatedAt, .distantPast)
        XCTAssertEqual(s.ageDescription, "never updated")
    }

    func testRoundTrip() {
        TailnetSnapshotStore.update(
            isConnected: true, tailnetIP: "100.1.2.3", socksProxy: "127.0.0.1:1080",
            tailnetName: "example@gmail.com", peerCount: 71, onlinePeerCount: 1
        )
        let s = TailnetSnapshotStore.load()
        XCTAssertTrue(s.isConnected)
        XCTAssertEqual(s.tailnetIP, "100.1.2.3")
        XCTAssertEqual(s.socksProxy, "127.0.0.1:1080")
        XCTAssertEqual(s.tailnetName, "example@gmail.com")
        XCTAssertEqual(s.peerCount, 71)
        XCTAssertEqual(s.onlinePeerCount, 1)
        XCTAssertEqual(s.ageDescription, "just now")
    }

    /// The connect path knows the IP; the peer poll knows the counts. Neither may
    /// clobber the other, or the intent reports a truth mixed with a stale blank.
    func testPartialUpdatePreservesOtherFields() {
        TailnetSnapshotStore.update(isConnected: true, tailnetIP: "100.1.2.3")
        TailnetSnapshotStore.update(peerCount: 71, onlinePeerCount: 2)

        let s = TailnetSnapshotStore.load()
        XCTAssertTrue(s.isConnected, "connection state survived a counts-only update")
        XCTAssertEqual(s.tailnetIP, "100.1.2.3", "IP survived a counts-only update")
        XCTAssertEqual(s.peerCount, 71)
        XCTAssertEqual(s.onlinePeerCount, 2)
    }

    /// Regression: counts written only by the peer-list view meant intents answered 0.
    func testCountsAreReadableWithoutVisitingThePeerList() {
        // Simulates connect() alone — no peer-list refresh.
        TailnetSnapshotStore.update(
            isConnected: true, tailnetIP: "100.1.2.3", peerCount: 71, onlinePeerCount: 1
        )
        let s = TailnetSnapshotStore.load()
        XCTAssertEqual(s.onlinePeerCount, 1, "connect must seed counts; 0 here is the shipped bug")
        XCTAssertEqual(s.peerCount, 71)
    }

    func testSignOutClearsEverything() {
        TailnetSnapshotStore.update(isConnected: true, tailnetIP: "100.1.2.3", peerCount: 5)
        TailnetSnapshotStore.clear()

        let s = TailnetSnapshotStore.load()
        XCTAssertFalse(s.isConnected, "a cleared snapshot must not still claim a connection")
        XCTAssertNil(s.tailnetIP)
        XCTAssertEqual(s.updatedAt, .distantPast)
    }

    func testAgeDescriptionQualifiesStaleState() {
        var s = TailnetSnapshot.empty
        s.updatedAt = Date().addingTimeInterval(-3 * 3600)
        TailnetSnapshotStore.save(s)
        let age = TailnetSnapshotStore.load().ageDescription
        XCTAssertTrue(age.contains("hour"), "expected an hours-scale age, got \(age)")
        XCTAssertTrue(age.hasSuffix("ago"))
    }
}
