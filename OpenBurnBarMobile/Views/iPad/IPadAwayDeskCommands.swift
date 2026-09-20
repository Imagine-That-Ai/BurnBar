import SwiftUI

/// iPadOS menu bar + hardware keyboard for the command desk.
///
/// Posts the same notifications the root already claims, so compact iPhone
/// ignores unknown names and regular iPad selects the desk destination.
struct IPadAwayDeskCommands: Commands {
    var body: some Commands {
        SidebarCommands()
        InspectorCommands()

        CommandMenu("View") {
            Button("Inbox") {
                NotificationCenter.default.post(name: IPadAwayDeskNotifications.selectInbox, object: nil)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Agents") {
                NotificationCenter.default.post(name: IPadAwayDeskNotifications.selectAgents, object: nil)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Quota") {
                NotificationCenter.default.post(name: IPadAwayDeskNotifications.selectQuota, object: nil)
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("You") {
                NotificationCenter.default.post(name: IPadAwayDeskNotifications.selectYou, object: nil)
            }
            .keyboardShortcut("4", modifiers: .command)

            Divider()

            Button("Pulse") {
                NotificationCenter.default.post(name: .init("NavigateToDashboard"), object: nil)
            }
            Button("Insights") {
                InsightsDeepLink.open()
            }
            Button("Streams") {
                NotificationCenter.default.post(name: .init("ShowStreamsTab"), object: nil)
            }
        }

        CommandMenu("Session") {
            Button("Approve") {
                NotificationCenter.default.post(name: IPadAwayDeskNotifications.approve, object: nil)
            }
            .keyboardShortcut(.return, modifiers: .command)

            Button("Halt") {
                NotificationCenter.default.post(name: IPadAwayDeskNotifications.halt, object: nil)
            }
            .keyboardShortcut(".", modifiers: .command)

            Button("Panic Halt") {
                NotificationCenter.default.post(name: IPadAwayDeskNotifications.halt, object: nil)
            }
            .keyboardShortcut(".", modifiers: [.control, .option, .command])

            Button("Ask to Mirror") {
                NotificationCenter.default.post(name: IPadAwayDeskNotifications.askToMirror, object: nil)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            // `.windowList` is macOS-only; the iOS SDK rejects it even for iPad.
            Button("Open Watch Window") {
                NotificationCenter.default.post(name: IPadAwayDeskNotifications.openWatchWindow, object: nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
        }
    }
}

enum IPadAwayDeskNotifications {
    static let selectInbox = Notification.Name("IPadAwayDeskSelectInbox")
    static let selectAgents = Notification.Name("IPadAwayDeskSelectAgents")
    static let selectQuota = Notification.Name("IPadAwayDeskSelectQuota")
    static let selectYou = Notification.Name("IPadAwayDeskSelectYou")
    static let pinWatch = Notification.Name("IPadAwayDeskPinWatch")
    static let openWatchWindow = Notification.Name("IPadAwayDeskOpenWatchWindow")
    static let approve = Notification.Name("IPadAwayDeskApprove")
    static let halt = Notification.Name("IPadAwayDeskHalt")
    static let askToMirror = Notification.Name("IPadAwayDeskAskToMirror")
}
