// Unit tests for `WebAuthLogin.LoginState` — the resume-exactly-once box behind
// the in-app Tailscale login sheet.
//
// WHY THIS FILE EXISTS
//
// Two independent paths finish the login: the session's completion handler, and
// the watcher that cancels the sheet once the node reaches Running. Both call
// into this state, and a `CheckedContinuation` MUST resume exactly once. A second
// resume is not a bad return value — it kills the process with
// `SWIFT TASK CONTINUATION MISUSE`, at the moment sign-in completes.
//
// Nothing in the type system enforces that. `resumeOnce` clearing `cont` is the
// entire mechanism, and it is four lines that look inert. This file is what
// notices if they stop working.
//
// The other half is `finish(userCancelled:)`, which decides what the caller
// learns. It has to tell two visually identical dismissals apart: the sheet
// closing because WE cancelled it on success, and the sheet closing because the
// user backed out. Both arrive as a cancellation. `autoDismissed` is the only
// thing that distinguishes them, and inverting that branch would report every
// successful login as a user cancellation — the app would sit on the login screen
// after a login that actually worked.
//
// Note the tests drive the continuation for real rather than mocking it. A mock
// would defeat the point: the trap being guarded against is a real runtime trap
// in the real type.

@testable import Tunnelless_iOS
import XCTest

@MainActor
final class WebAuthLoginStateTests: XCTestCase {
    // MARK: - resumeOnce

    /// The core guarantee. A second `resumeOnce` must be a silent no-op; if it is
    /// not, this test does not fail politely, it CRASHES the test runner with
    /// SWIFT TASK CONTINUATION MISUSE. That is the correct signal — the same
    /// crash would take the app down mid-login.
    func testSecondResumeIsANoOp() async {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let state = WebAuthLogin.LoginState(cont)
            state.resumeOnce(true)
            state.resumeOnce(false) // must not resume again
            state.resumeOnce(true) // nor a third time
        }
        XCTAssertTrue(result, "the FIRST resume must win; later ones are dropped")
    }

    /// The first value is the one delivered, whichever it is — the guard is not
    /// "always true", it is "whatever arrived first".
    func testFirstResumeWinsWhenItIsFalse() async {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let state = WebAuthLogin.LoginState(cont)
            state.resumeOnce(false)
            state.resumeOnce(true)
        }
        XCTAssertFalse(result)
    }

    // MARK: - finish(userCancelled:)

    /// The user tapped Cancel and we had not dismissed the sheet ourselves, so
    /// login did not happen: report false.
    func testUserCancellationReportsFailure() async {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let state = WebAuthLogin.LoginState(cont)
            state.finish(userCancelled: true)
        }
        XCTAssertFalse(result)
    }

    /// The session completed on its own without a cancellation: login succeeded.
    func testNaturalCompletionReportsSuccess() async {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let state = WebAuthLogin.LoginState(cont)
            state.finish(userCancelled: false)
        }
        XCTAssertTrue(result)
    }

    /// The case the whole `autoDismissed` flag exists for, and the one most likely
    /// to regress. When the node comes up we cancel the sheet OURSELVES; the
    /// system then reports that as a user cancellation, because from its point of
    /// view a cancel is a cancel. Without the flag this would report false and the
    /// app would stay on the login screen after a login that succeeded.
    func testSelfDismissalOnSuccessIsNotMistakenForUserCancellation() async {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let state = WebAuthLogin.LoginState(cont)
            state.autoDismissed = true
            state.finish(userCancelled: true) // arrives looking exactly like a cancel
        }
        XCTAssertTrue(result, "autoDismissed must outrank the cancellation flag")
    }

    /// `autoDismissed` wins regardless of what the completion handler reports, so
    /// the success path does not depend on the system's cancellation bookkeeping.
    func testSelfDismissalReportsSuccessWhenNotFlaggedCancelled() async {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let state = WebAuthLogin.LoginState(cont)
            state.autoDismissed = true
            state.finish(userCancelled: false)
        }
        XCTAssertTrue(result)
    }

    // MARK: - The watcher

    /// `finish` cancels the watcher, so the safety-net task cannot fire a second
    /// resume after the completion handler already settled things.
    func testFinishCancelsTheWatcher() async {
        var watcher: Task<Void, Never>?
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let state = WebAuthLogin.LoginState(cont)
            let t = Task { @MainActor in
                // Long enough that it is still pending when finish() runs.
                // `_ =` so the closure returns Void, not `()?` — `try? await`
                // yields an optional and Task<Void, Never> will not take it.
                _ = try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            state.watcher = t
            watcher = t
            state.finish(userCancelled: false)
        }
        XCTAssertTrue(result)
        await watcher?.value
        XCTAssertTrue(watcher?.isCancelled == true, "finish() must cancel the watcher")
    }
}
