import Foundation

extension OpenBurnBarOperatingLayer {
    func refreshControllerRuntime() async {
        guard settingsManager.controllerRuntimeEnabled else {
            stateRevision += 1
            return
        }

        do {
            if case .healthy = daemonManager.status {
                try await daemonManager.syncControllerNotificationConfiguration(from: settingsManager)
                let snapshot = try await daemonManager.fetchControllerRuntimeSnapshot()
                try await dataStore.saveControllerRuntimeMirror(snapshot)
                rememberControllerRuntimeMirror(snapshot)
            }
            controllerFeedback = nil
        } catch {
            controllerFeedback = OpenBurnBarControllerFeedback(
                tone: .error,
                message: "Controller runtime refresh fell back to the local mirror: \(error.localizedDescription)"
            )
        }
        stateRevision += 1
    }

    func answerPendingQuestion(id: String, answer: String, selectedOptionID: String? = nil) async {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            controllerFeedback = OpenBurnBarControllerFeedback(tone: .error, message: "Write an answer before sending it to OpenBurnBar.")
            return
        }

        do {
            if case .healthy = daemonManager.status {
                if let snapshot = try await daemonManager.answerControllerQuestion(
                    questionID: id,
                    answer: trimmed,
                    selectedOptionID: selectedOptionID
                ) {
                    try await dataStore.saveControllerRuntimeMirror(snapshot)
                } else {
                    try await dataStore.saveControllerRuntimeMirror(self.snapshot.controllerRuntime)
                    _ = try await dataStore.answerControllerQuestion(id: id, answer: trimmed, selectedOptionID: selectedOptionID)
                }
            } else {
                try await dataStore.saveControllerRuntimeMirror(self.snapshot.controllerRuntime)
                _ = try await dataStore.answerControllerQuestion(id: id, answer: trimmed, selectedOptionID: selectedOptionID)
            }
            controllerFeedback = OpenBurnBarControllerFeedback(tone: .success, message: "Answer recorded in OpenBurnBar’s controller history.")
            await refreshControlPlaneCache()
            stateRevision += 1
        } catch {
            controllerFeedback = OpenBurnBarControllerFeedback(tone: .error, message: "OpenBurnBar could not record that answer: \(error.localizedDescription)")
        }
    }

    func completeFollowup(id: String) async {
        do {
            if case .healthy = daemonManager.status {
                if let snapshot = try await daemonManager.completeControllerFollowup(followupID: id) {
                    try await dataStore.saveControllerRuntimeMirror(snapshot)
                } else {
                    try await dataStore.saveControllerRuntimeMirror(self.snapshot.controllerRuntime)
                    _ = try await dataStore.completeControllerFollowup(id: id)
                }
            } else {
                try await dataStore.saveControllerRuntimeMirror(self.snapshot.controllerRuntime)
                _ = try await dataStore.completeControllerFollowup(id: id)
            }
            controllerFeedback = OpenBurnBarControllerFeedback(tone: .success, message: "Followup completed.")
            await refreshControlPlaneCache()
            stateRevision += 1
        } catch {
            controllerFeedback = OpenBurnBarControllerFeedback(tone: .error, message: "OpenBurnBar could not complete that followup: \(error.localizedDescription)")
        }
    }

    func snoozeFollowup(id: String, until: Date) async {
        do {
            if case .healthy = daemonManager.status {
                if let snapshot = try await daemonManager.snoozeControllerFollowup(followupID: id, until: until) {
                    try await dataStore.saveControllerRuntimeMirror(snapshot)
                } else {
                    try await dataStore.saveControllerRuntimeMirror(self.snapshot.controllerRuntime)
                    _ = try await dataStore.snoozeControllerFollowup(id: id, until: until)
                }
            } else {
                try await dataStore.saveControllerRuntimeMirror(self.snapshot.controllerRuntime)
                _ = try await dataStore.snoozeControllerFollowup(id: id, until: until)
            }
            controllerFeedback = OpenBurnBarControllerFeedback(tone: .success, message: "Followup snoozed until \(until.formatted(date: .abbreviated, time: .shortened)).")
            await refreshControlPlaneCache()
            stateRevision += 1
        } catch {
            controllerFeedback = OpenBurnBarControllerFeedback(tone: .error, message: "OpenBurnBar could not snooze that followup: \(error.localizedDescription)")
        }
    }

    func scheduleFollowupCalendar(id: String, title: String? = nil) async {
        let start = Date().addingTimeInterval(60 * 30)
        let duration = settingsManager.controllerCalendarDefaultMinutes
        do {
            if case .healthy = daemonManager.status {
                if let snapshot = try await daemonManager.scheduleControllerFollowupCalendar(
                    followupID: id,
                    title: title,
                    start: start,
                    durationMinutes: duration
                ) {
                    try await dataStore.saveControllerRuntimeMirror(snapshot)
                } else {
                    try await dataStore.saveControllerRuntimeMirror(self.snapshot.controllerRuntime)
                    _ = try await dataStore.scheduleControllerFollowupCalendar(
                        id: id,
                        title: title,
                        start: start,
                        durationMinutes: duration
                    )
                }
            } else {
                try await dataStore.saveControllerRuntimeMirror(self.snapshot.controllerRuntime)
                _ = try await dataStore.scheduleControllerFollowupCalendar(
                    id: id,
                    title: title,
                    start: start,
                    durationMinutes: duration
                )
            }
            controllerFeedback = OpenBurnBarControllerFeedback(
                tone: .success,
                message: "Calendar hold added for \(start.formatted(date: .abbreviated, time: .shortened))."
            )
            await refreshControlPlaneCache()
            stateRevision += 1
        } catch {
            controllerFeedback = OpenBurnBarControllerFeedback(tone: .error, message: "OpenBurnBar could not add that calendar hold: \(error.localizedDescription)")
        }
    }
}
