// Unit tests for the log-line parsing that drives the whole login flow.
//
// WHY THIS FILE EXISTS
//
// `app/Shared/Tailscale/` is 1,211 lines and had no unit coverage at all —
// `TailscaleNodeManager`, `TailnetStatusClient`, `WebAuthLogin` and
// `DiagnosticProbes` were referenced by zero tests. That layer is also the part
// v0.3 wants to turn into a module, and 1,200 lines cannot be refactored into an
// API safely with nothing underneath them.
//
// These two parsers are load-bearing in a way that is easy to miss: on a stock
// build, `LocalAPIClient` is unusable for the entire login window (TAILSCALE.md
// §1, libtailscale#58), so reading tsnet's log stream is the ONLY way to observe
// login state. If `authURL(from:)` stops matching, the app never opens a browser
// and login hangs forever. If `reportsRunning(_:)` stops matching, the login
// sheet never dismisses. Neither failure produces an error — both just wait.
//
// The banner case below is a recorded trap, not a hypothetical: tsnet also logs
// a friendlier "…go to: <url>" line, which is written to a DIFFERENT file
// descriptor and never reaches this pipe. Matching on it looks correct and
// silently never fires.

@testable import Tunnelless_iOS
import XCTest

final class TailscaleNodeManagerTests: XCTestCase {
    /// `init` only stores a hostname — it starts no node and touches no network,
    /// so the nonisolated parsers can be exercised directly.
    private let mgr = TailscaleNodeManager(hostName: "test-node")

    // MARK: - authURL(from:)

    func testAuthURLExtractsTheInteractiveLoginURL() {
        let line = "control: AuthURL is https://login.tailscale.com/a/0123456789abcdef"
        XCTAssertEqual(mgr.authURL(from: line)?.absoluteString,
                       "https://login.tailscale.com/a/0123456789abcdef")
    }

    func testAuthURLTrimsTrailingWhitespace() {
        let line = "control: AuthURL is https://login.tailscale.com/a/abc   "
        XCTAssertEqual(mgr.authURL(from: line)?.absoluteString,
                       "https://login.tailscale.com/a/abc")
    }

    /// The recorded trap. tsnet's friendlier banner carries the same URL but no
    /// "AuthURL is " marker, and it never reaches this pipe anyway. A parser that
    /// accepted it would look correct and silently never fire in production.
    func testAuthURLIgnoresTheFriendlierBannerForm() {
        let banner = "To start this tsnet server, restart with TS_AUTHKEY set, "
            + "or go to: https://login.tailscale.com/a/abc"
        XCTAssertNil(mgr.authURL(from: banner))
    }

    func testAuthURLIgnoresUnrelatedLines() {
        XCTAssertNil(mgr.authURL(from: "Switching ipn state NoState -> NeedsLogin"))
        XCTAssertNil(mgr.authURL(from: ""))
        XCTAssertNil(mgr.authURL(from: "logtail started"))
    }

    /// Guards the marker itself: the match is on "AuthURL is ", trailing space
    /// included, so a line that merely mentions the word does not parse.
    func testAuthURLRequiresTheFullMarker() {
        XCTAssertNil(mgr.authURL(from: "control: AuthURL was https://example.com/a"))
    }

    // MARK: - reportsRunning(_:)

    func testReportsRunningMatchesTheTransitionIntoRunning() {
        XCTAssertTrue(mgr.reportsRunning("Switching ipn state NeedsLogin -> Running"))
        XCTAssertTrue(mgr.reportsRunning("Switching ipn state Starting -> Running"))
        XCTAssertTrue(mgr.reportsRunning("Switching ipn state NoState -> Running"))
    }

    /// Transitions AWAY from Running must not read as "logged in". Getting this
    /// backwards would dismiss the login sheet as the node is shutting down.
    func testReportsRunningIgnoresTransitionsAwayFromRunning() {
        XCTAssertFalse(mgr.reportsRunning("Switching ipn state Running -> Stopped"))
        XCTAssertFalse(mgr.reportsRunning("Switching ipn state Running -> NoState"))
    }

    func testReportsRunningIgnoresOtherTransitions() {
        XCTAssertFalse(mgr.reportsRunning("Switching ipn state NoState -> NeedsLogin"))
        XCTAssertFalse(mgr.reportsRunning("Switching ipn state NeedsLogin -> Starting"))
    }

    /// The word alone is not the signal — plenty of tsnet lines contain it.
    func testReportsRunningIgnoresIncidentalMentions() {
        XCTAssertFalse(mgr.reportsRunning("tsnet running on 100.84.19.7"))
        XCTAssertFalse(mgr.reportsRunning("Running"))
        XCTAssertFalse(mgr.reportsRunning(""))
    }

    // MARK: - State equality

    //
    // `TailscaleNodeState.==` is hand-written with a `default: false` arm, which
    // is exactly the shape that silently starts returning false for a case
    // someone adds later.

    func testStateEqualityMatchesLikeForLike() {
        XCTAssertEqual(TailscaleNodeState.idle, .idle)
        XCTAssertEqual(TailscaleNodeState.starting, .starting)
        XCTAssertEqual(TailscaleNodeState.connected(ip: "100.84.19.7"),
                       .connected(ip: "100.84.19.7"))
        XCTAssertEqual(TailscaleNodeState.failed("boom"), .failed("boom"))
    }

    func testStateEqualityDistinguishesPayloads() {
        XCTAssertNotEqual(TailscaleNodeState.connected(ip: "100.84.19.7"),
                          .connected(ip: "100.84.19.8"))
        XCTAssertNotEqual(TailscaleNodeState.failed("a"), .failed("b"))
    }

    func testStateEqualityDistinguishesCases() {
        XCTAssertNotEqual(TailscaleNodeState.idle, .starting)
        XCTAssertNotEqual(TailscaleNodeState.idle, .connected(ip: "100.84.19.7"))
        XCTAssertNotEqual(TailscaleNodeState.starting, .failed("x"))
        XCTAssertNotEqual(TailscaleNodeState.connected(ip: "x"), .failed("x"))
    }

    // MARK: - stateDirPath()

    //
    // Sign-out MUST delete this directory: leaving it means tsnet reuses the
    // persisted auth, never re-logs the auth URL, and the next login waits
    // forever on a line that will not come.

    func testStateDirPathIsStableAndNamed() {
        let a = TailscaleNodeManager.stateDirPath()
        let b = TailscaleNodeManager.stateDirPath()
        XCTAssertEqual(a, b, "path must not vary between calls; sign-out deletes what start created")
        XCTAssertTrue(a.hasSuffix("/tsnet-state"), "unexpected leaf: \(a)")
        XCTAssertTrue(a.hasPrefix("/"), "expected an absolute path, got: \(a)")
    }

    func testErrorEquality() {
        XCTAssertEqual(TailscaleNodeError.notStarted, .notStarted)
        XCTAssertNotEqual(TailscaleNodeError.notStarted, .loginTimedOut)
        XCTAssertNotEqual(TailscaleNodeError.noAddress, .loginTimedOut)
    }
}
