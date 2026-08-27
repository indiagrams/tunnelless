// WebAuthLogin.swift
//
// Presents the Tailscale interactive login inside the app and brings the user
// straight back when the node comes up.
//
// WHY NOT a plain SwiftUI `Link`: that hands off to Safari, and Tailscale's flow
// ends on console.tailscale.com — there is no redirect back to the app. The user
// is stranded in a browser and has to find the back button themselves.
//
// ASWebAuthenticationSession solves it, but not through a callback URL. Tailscale
// never redirects to a custom scheme, so `callbackURLScheme` is nil and the session
// would sit open forever. Instead we watch the node itself: when the up-task
// completes (node reached Running) we cancel the session, which dismisses the sheet
// and returns the user to the app automatically.

import AuthenticationServices
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

@MainActor
enum WebAuthLogin {
    /// Opens `url` in an in-app auth sheet.
    ///
    /// - Parameter dismissWhen: when this task completes (node reached Running), the
    ///   sheet is dismissed automatically. Pass the manager's up-task.
    /// - Returns: true if login completed or was auto-dismissed on success;
    ///   false if the user cancelled.
    @discardableResult
    static func present(url: URL, dismissWhen upTask: Task<Void, Error>?) async -> Bool {
        // WHY outer scope: `session.presentationContextProvider` is a WEAK property.
        // Created inline inside withCheckedContinuation there is no strong holder, ARC
        // releases it immediately, the weak ref goes nil, and start() fails with Code=2.
        #if os(iOS)
            let presenter = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
                .map { ScenePresenter(scene: $0) }
        #elseif os(macOS)
            let presenter = WindowPresenter()
        #endif

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // All the mutable state lives on this @MainActor box rather than in local
            // vars. Two reasons, and the second one is a crash:
            //
            // 1. Two paths can finish the continuation — the session's completion
            //    handler and the watcher safety net below — and it must resume exactly
            //    once.
            //
            // 2. The completion handler below has to be @Sendable, and a @Sendable
            //    closure cannot capture mutable local `var`s. A @MainActor class is
            //    implicitly Sendable, so the closure can capture this by reference and
            //    still reach the state through an explicit hop.
            let state = LoginState(cont)

            let session = makeSession(url: url, state: state)
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = presenter
            session.start()

            guard let upTask else { return }
            state.watcher = Task { @MainActor in
                try? await upTask.value // resolves when the node reaches Running
                guard !Task.isCancelled else { return }
                state.autoDismissed = true
                session.cancel() // dismisses the sheet → back in the app

                // Safety net: if the system already tore the sheet down (Safari-style back
                // navigation, or iOS intercepting the redirect), the completion handler may
                // never fire. One run-loop turn is enough for it to run if it was going to;
                // resumeOnce is idempotent either way.
                await Task.yield()
                state.resumeOnce(true)
            }
        }
    }

    // MARK: - Session construction

    /// Builds the session, and with it the completion handler.
    ///
    /// WHY this is `nonisolated` and not inlined into `present`: the completion
    /// handler must not be main-actor isolated. `ASWebAuthenticationSession` does not
    /// deliver it on the main thread on macOS — it arrives on the XPC reply queue of
    /// Safari's launch agent (com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent).
    /// iOS delivers it on the main thread, which is why only the Mac crashed.
    ///
    /// `ASWebAuthenticationSessionCompletionHandler` is a plain ObjC block with no
    /// `NS_SWIFT_SENDABLE`, so a closure literal written inside this `@MainActor` enum
    /// inherits the enum's isolation. Swift then emits an executor precondition in the
    /// block thunk which trips the instant the block runs off-main:
    /// `swift_task_isCurrentExecutorWithFlags` → `dispatch_assert_queue` →
    /// `EXC_BREAKPOINT` (SIGTRAP), killing the app exactly when login finishes.
    ///
    /// That check fires on ENTRY, before any statement in the body, so hopping to the
    /// main actor *inside* the closure does not help — and `@Sendable` alone does not
    /// help either, because in Swift 6 a closure can be both `@Sendable` and isolated.
    /// Forming the closure in a `nonisolated` context is what actually removes the
    /// isolation. `LoginState` is `@MainActor` (hence `Sendable`), so the captured
    /// state is still reached through an explicit hop.
    ///
    /// Guard against regression: moving this closure back inside `present` compiles
    /// cleanly and crashes only at runtime, on macOS, at the moment sign-in completes.
    private nonisolated static func makeSession(
        url: URL, state: LoginState
    ) -> ASWebAuthenticationSession {
        ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, error in
            let userCancelled =
                (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            Task { @MainActor in state.finish(userCancelled: userCancelled) }
        }
    }

    // MARK: - Login state

    /// The mutable half of `present`, held on the main actor.
    ///
    /// Exists so the session's completion handler can be `@Sendable`: that closure
    /// cannot capture mutable local `var`s, but a `@MainActor` class is implicitly
    /// `Sendable`, so it can capture one of these and reach the state through a hop.
    @MainActor
    private final class LoginState {
        /// Set before we cancel the session ourselves, so the completion handler can
        /// tell "we dismissed it because login succeeded" from "the user tapped Cancel".
        var autoDismissed = false
        var watcher: Task<Void, Never>?

        private var cont: CheckedContinuation<Bool, Never>?

        init(_ cont: CheckedContinuation<Bool, Never>) {
            self.cont = cont
        }

        /// Idempotent: two paths race to finish, and a CheckedContinuation must
        /// resume exactly once. Clearing `cont` is what makes the second call a no-op.
        func resumeOnce(_ value: Bool) {
            guard let c = cont else { return }
            cont = nil
            c.resume(returning: value)
        }

        func finish(userCancelled: Bool) {
            watcher?.cancel()
            if autoDismissed {
                resumeOnce(true) // we closed it — the node is up
                return
            }
            resumeOnce(!userCancelled) // false = user backed out
        }
    }

    // MARK: - Presentation anchors

    #if os(iOS)
        private final class ScenePresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
            let scene: UIWindowScene
            init(scene: UIWindowScene) {
                self.scene = scene
            }

            func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
                scene.windows.first ?? ASPresentationAnchor()
            }
        }
    #elseif os(macOS)
        /// On macOS the anchor is an NSWindow, not a UIWindowScene.
        private final class WindowPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
            func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
                NSApplication.shared.windows.first(where: \.isKeyWindow)
                    ?? NSApplication.shared.windows.first
                    ?? NSWindow()
            }
        }
    #endif
}
