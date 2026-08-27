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

        // Set before we call cancel() ourselves, so the completion handler can tell
        // "we dismissed it because login succeeded" from "the user tapped Cancel".
        var autoDismissed = false
        var watcher: Task<Void, Never>?

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // Two paths can finish this: the session's completion handler, and the
            // watcher safety net below. CheckedContinuation must resume exactly once.
            var resumed = false
            func resumeOnce(_ value: Bool) {
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }

            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, error in
                // WHY the main-actor hop: this completion handler is NOT delivered on
                // the main thread on macOS. AuthenticationServices runs the callback on
                // the XPC reply queue of its Safari launch agent
                // (com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent), while
                // on iOS it arrives on the main thread — which is why this only ever
                // crashed on the Mac.
                //
                // Everything below (`watcher`, `autoDismissed`, `resumeOnce` and the
                // continuation it closes over) is main-actor state, because `present`
                // is a member of this @MainActor enum. Touching it from the XPC queue
                // trips the runtime's isolation check —
                // swift_task_isCurrentExecutorWithFlags → dispatch_assert_queue →
                // EXC_BREAKPOINT (SIGTRAP), killing the app at the moment login
                // succeeds. Reading the cancellation flag here is safe (it is a local
                // Bool derived from the error); every isolated access happens inside
                // the hop.
                let userCancelled =
                    (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                Task { @MainActor in
                    watcher?.cancel()
                    if autoDismissed {
                        resumeOnce(true) // we closed it — the node is up
                        return
                    }
                    resumeOnce(!userCancelled) // false = user backed out
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = presenter
            session.start()

            guard let upTask else { return }
            watcher = Task { @MainActor in
                try? await upTask.value // resolves when the node reaches Running
                guard !Task.isCancelled else { return }
                autoDismissed = true
                session.cancel() // dismisses the sheet → back in the app

                // Safety net: if the system already tore the sheet down (Safari-style back
                // navigation, or iOS intercepting the redirect), the completion handler may
                // never fire. One run-loop turn is enough for it to run if it was going to;
                // resumeOnce is idempotent either way.
                await Task.yield()
                resumeOnce(true)
            }
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
