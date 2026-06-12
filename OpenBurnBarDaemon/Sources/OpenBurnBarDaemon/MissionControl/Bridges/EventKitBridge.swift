import OpenBurnBarCore
import EventKit
import Foundation

actor BurnBarEventKitBridge {
    static let shared = BurnBarEventKitBridge()

    private let store = EKEventStore()

    func apply(
        action: BurnBarCalendarAction,
        entry: BurnBarCalendarEntrySnapshot,
        preferredCalendarName: String?
    ) async throws -> BurnBarCalendarEntrySnapshot {
        try await ensureAccess()

        switch action {
        case .create, .update:
            let event = existingEvent(for: entry) ?? EKEvent(eventStore: store)
            guard let calendar = resolvedCalendar(named: preferredCalendarName) else {
                throw NSError(
                    domain: "BurnBarEventKitBridge",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No writable calendar is available for OpenBurnBar followups."]
                )
            }
            event.calendar = calendar
            event.title = entry.title
            let start = entry.startAt ?? Date().addingTimeInterval(3600)
            let end = entry.endAt ?? start.addingTimeInterval(1800)
            event.startDate = start
            event.endDate = max(end, start.addingTimeInterval(60))
            event.notes = entry.notes
            try store.save(event, span: .thisEvent, commit: true)
            return BurnBarCalendarEntrySnapshot(
                externalID: event.eventIdentifier,
                title: entry.title,
                startAt: event.startDate,
                endAt: event.endDate,
                notes: entry.notes
            )
        case .remove:
            if let event = existingEvent(for: entry) {
                try store.remove(event, span: .thisEvent, commit: true)
            }
            return BurnBarCalendarEntrySnapshot(
                externalID: nil,
                title: entry.title,
                startAt: entry.startAt,
                endAt: entry.endAt,
                notes: entry.notes
            )
        }
    }

    private func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized, .writeOnly:
            return
        case .notDetermined:
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await withCheckedThrowingContinuation { continuation in
                    store.requestFullAccessToEvents { allowed, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: allowed)
                        }
                    }
                }
            } else {
                granted = try await withCheckedThrowingContinuation { continuation in
                    store.requestAccess(to: .event) { allowed, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: allowed)
                        }
                    }
                }
            }
            guard granted else {
                throw NSError(
                    domain: "BurnBarEventKitBridge",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access was denied for OpenBurnBar followup scheduling."]
                )
            }
        case .restricted, .denied:
            throw NSError(
                domain: "BurnBarEventKitBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Calendar access is unavailable for OpenBurnBar followup scheduling."]
            )
        @unknown default:
            throw NSError(
                domain: "BurnBarEventKitBridge",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "OpenBurnBar does not recognize the current calendar authorization status."]
            )
        }
    }

    private func existingEvent(for entry: BurnBarCalendarEntrySnapshot) -> EKEvent? {
        guard let externalID = entry.externalID else { return nil }
        return store.event(withIdentifier: externalID)
    }

    private func resolvedCalendar(named preferredCalendarName: String?) -> EKCalendar? {
        if let preferredCalendarName, preferredCalendarName.isEmpty == false {
            if let match = store.calendars(for: .event).first(where: {
                $0.allowsContentModifications
                    && $0.title.compare(preferredCalendarName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                return match
            }
        }
        return store.defaultCalendarForNewEvents
            ?? store.calendars(for: .event).first(where: \.allowsContentModifications)
    }
}
