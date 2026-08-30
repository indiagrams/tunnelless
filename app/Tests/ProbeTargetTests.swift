// Unit tests for `ProbeTarget.parse` — the `host:port[/path]` launch-argument
// parser behind `-probe` and `-service`.
//
// WHY THIS FILE EXISTS
//
// The parsing was inline, twice, in `DiagnosticProbes.swift`, with `-service`'s
// copy a strict superset of `-probe`'s. Both only run behind a launch argument on
// a physical device, which is the worst place to discover a parser is wrong: the
// probes exist to MEASURE things the Simulator cannot show, so a bad parse there
// discredits the measurement rather than announcing itself.
//
// Two index choices in that parser look interchangeable and are not:
//
//   - the colon is found with `lastIndex`, because an IPv6 literal like
//     `[::1]:8080` is full of colons and only the final one precedes the port.
//     `firstIndex` splits inside the address and parses a nonsense port.
//   - the slash is found with `firstIndex`, because the path starts at the first
//     slash and every later slash belongs to the path.
//
// Swap either and most inputs still parse. The tests below are chosen so that a
// swap fails: `testIPv6LiteralSplitsOnTheFinalColon` dies if the colon search
// changes, `testPathKeepsItsOwnSlashes` dies if the slash search changes.
//
// `UInt16` is likewise load-bearing — it is what rejects a port above 65535.
// Widening it to `Int` would accept 70000 and truncate silently.

@testable import Tunnelless_iOS
import XCTest

final class ProbeTargetTests: XCTestCase {
    // MARK: - The ordinary shapes

    func testHostAndPort() {
        let t = ProbeTarget.parse("peer.example.ts.net:8080")
        XCTAssertEqual(t?.host, "peer.example.ts.net")
        XCTAssertEqual(t?.port, 8080)
    }

    /// A target with no path still yields a usable one, so callers never have to
    /// special-case it into a request line.
    func testMissingPathDefaultsToRoot() {
        XCTAssertEqual(ProbeTarget.parse("host:80")?.path, "/")
    }

    func testPathIsPreserved() {
        let t = ProbeTarget.parse("host:80/status")
        XCTAssertEqual(t?.host, "host")
        XCTAssertEqual(t?.port, 80)
        XCTAssertEqual(t?.path, "/status")
    }

    // MARK: - The two index choices

    /// Pins `lastIndex` for the colon. With `firstIndex` the host becomes "[" and
    /// the port parse fails on ":1]:8080", so this returns nil and the test fails.
    func testIPv6LiteralSplitsOnTheFinalColon() {
        let t = ProbeTarget.parse("[::1]:8080")
        XCTAssertEqual(t?.host, "[::1]")
        XCTAssertEqual(t?.port, 8080)
    }

    /// Pins `firstIndex` for the slash. With `lastIndex` the authority swallows
    /// "/a" and the port parse fails on "80/a", returning nil.
    func testPathKeepsItsOwnSlashes() {
        let t = ProbeTarget.parse("host:80/a/b/c")
        XCTAssertEqual(t?.host, "host")
        XCTAssertEqual(t?.port, 80)
        XCTAssertEqual(t?.path, "/a/b/c")
    }

    /// The authority is split off before the colon search, so a colon inside the
    /// path cannot be mistaken for the port separator.
    func testColonInsideThePathIsNotThePortSeparator() {
        let t = ProbeTarget.parse("host:80/a:b")
        XCTAssertEqual(t?.host, "host")
        XCTAssertEqual(t?.port, 80)
        XCTAssertEqual(t?.path, "/a:b")
    }

    // MARK: - Rejection

    func testRejectsMissingColon() {
        XCTAssertNil(ProbeTarget.parse("hostonly"))
        XCTAssertNil(ProbeTarget.parse("host/path"))
    }

    func testRejectsNonNumericPort() {
        XCTAssertNil(ProbeTarget.parse("host:http"))
        XCTAssertNil(ProbeTarget.parse("host:80x"))
    }

    /// The reason the type is `UInt16` and not `Int`. 65535 is the last valid
    /// port; 65536 must not become 0, and 70000 must not become 4464.
    func testRejectsPortAboveSixtyFiveThousandFiveHundredThirtyFive() {
        XCTAssertEqual(ProbeTarget.parse("host:65535")?.port, 65535)
        XCTAssertNil(ProbeTarget.parse("host:65536"))
        XCTAssertNil(ProbeTarget.parse("host:70000"))
    }

    func testRejectsEmptyPort() {
        XCTAssertNil(ProbeTarget.parse("host:"))
        XCTAssertNil(ProbeTarget.parse("host:/path"))
    }

    func testRejectsNegativePort() {
        XCTAssertNil(ProbeTarget.parse("host:-1"))
    }

    func testRejectsEmptyInput() {
        XCTAssertNil(ProbeTarget.parse(""))
    }

    // MARK: - Recorded behaviour, not endorsed behaviour

    /// An empty host currently PARSES. Documented rather than asserted-against
    /// because the probes are developer-only launch arguments and a connection to
    /// an empty host fails immediately and visibly — tightening it would be a
    /// behaviour change this test suite is not the place to smuggle in.
    /// If `ProbeTarget` ever becomes part of a public API, reject this first.
    func testEmptyHostIsAcceptedToday() {
        let t = ProbeTarget.parse(":8080")
        XCTAssertEqual(t?.host, "")
        XCTAssertEqual(t?.port, 8080)
    }

    /// Likewise port 0, which is syntactically a valid UInt16 and semantically
    /// useless. Recorded so a future change to reject it is a deliberate one.
    func testPortZeroIsAcceptedToday() {
        XCTAssertEqual(ProbeTarget.parse("host:0")?.port, 0)
    }
}
