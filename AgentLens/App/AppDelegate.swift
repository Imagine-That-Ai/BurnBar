import AppKit
import Carbon
import GoogleSignIn

/// Handles OAuth redirect URLs for Google Sign-In (menu bar apps need Apple Event + open-URL).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if AppCommandRouter.shared.handle(url) {
            return
        }
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OpenBurnBarRuntime.beginHarnessHostActivityIfNeeded()

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        if AppCommandRouter.shared.handle(url) {
            return
        }
        _ = GIDSignIn.sharedInstance.handle(url)
    }
}
