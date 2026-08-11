import Foundation
import OpenBurnBarEngine

// MARK: - Founder Lens storage (threads, plan ledger, memory export)
//
// Same raw-sqlite discipline as the base store: every public method serializes
// through `databaseSync`, timestamps are ISO-8601 strings, and JSON columns are
// encoded with stable ISO dates so rows stay readable from Python/sqlite3.
extension BurnBarAIInboxStore {
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Threads

    /// Appends a turn, creating the thread row on first use and soft-binding
    /// the latest item id (L1: fingerprint is the identity, item id is a hint).
    func appendThreadMessage(
        _ message: BurnBarInboxThreadMessage,
        itemID: String?,
        now: Date
    ) throws {
        try databaseSync {
            try execute("BEGIN IMMEDIATE", [])
            do {
                let stamp = Self.string(from: now)
                try execute(
                    """
                    INSERT INTO ai_inbox_threads(fingerprint, item_id, created_at, updated_at, turn_count, total_cost_usd)
                    VALUES (?, ?, ?, ?, 1, ?)
                    ON CONFLICT(fingerprint) DO UPDATE SET
                        item_id = COALESCE(excluded.item_id, ai_inbox_threads.item_id),
                        updated_at = excluded.updated_at,
                        turn_count = ai_inbox_threads.turn_count + 1,
                        total_cost_usd = ai_inbox_threads.total_cost_usd + excluded.total_cost_usd
                    """,
                    [
                        .text(message.fingerprint),
                        .optionalText(itemID),
                        .text(stamp),
                        .text(stamp),
                        .double(message.costUSD)
                    ]
                )
                let candidatesJSON: String?
                if message.planCandidates.isEmpty {
                    candidatesJSON = nil
                } else {
                    candidatesJSON = String(
                        data: try Self.jsonEncoder.encode(message.planCandidates),
                        encoding: .utf8
                    )
                }
                try execute(
                    """
                    INSERT INTO ai_inbox_thread_messages(id, fingerprint, role, body_md, plan_candidates_json, model_provenance, cost_usd, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(message.id),
                        .text(message.fingerprint),
                        .text(message.role.rawValue),
                        .text(message.bodyMarkdown),
                        .optionalText(candidatesJSON),
                        .optionalText(message.modelProvenance),
                        .double(message.costUSD),
                        .text(Self.string(from: message.createdAt))
                    ]
                )
                try execute("COMMIT", [])
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    func thread(fingerprint: String, messageLimit: Int = 200) throws -> BurnBarInboxThread? {
        try databaseSync {
            guard let head = try queryRows(
                """
                SELECT fingerprint, item_id, created_at, updated_at, turn_count, total_cost_usd
                FROM ai_inbox_threads WHERE fingerprint = ? LIMIT 1
                """,
                [.text(fingerprint)]
            ).first else { return nil }

            // Newest turns first so the limit keeps the RECENT window (the
            // prompt context and the UI both want "latest N"), then reversed
            // back to chronological order for presentation.
            let rows = try queryRows(
                """
                SELECT id, fingerprint, role, body_md, plan_candidates_json, model_provenance, cost_usd, created_at
                FROM ai_inbox_thread_messages
                WHERE fingerprint = ?
                ORDER BY created_at DESC, id DESC
                LIMIT ?
                """,
                [.text(fingerprint), .int(max(1, messageLimit))]
            )
            let messages = rows.compactMap(Self.threadMessage(from:)).reversed()
            return BurnBarInboxThread(
                fingerprint: head.string(0),
                itemID: head.optionalString(1),
                createdAt: head.date(2) ?? Date(timeIntervalSince1970: 0),
                updatedAt: head.date(3) ?? Date(timeIntervalSince1970: 0),
                turnCount: head.int(4),
                totalCostUSD: head.double(5),
                messages: Array(messages)
            )
        }
    }

    private static func threadMessage(from row: Row) -> BurnBarInboxThreadMessage? {
        guard let role = BurnBarInboxThreadMessage.Role(rawValue: row.string(2)) else { return nil }
        var candidates: [BurnBarInboxPlanCandidate] = []
        if let json = row.optionalString(4), let data = json.data(using: .utf8) {
            candidates = (try? jsonDecoder.decode([BurnBarInboxPlanCandidate].self, from: data)) ?? []
        }
        return BurnBarInboxThreadMessage(
            id: row.string(0),
            fingerprint: row.string(1),
            role: role,
            bodyMarkdown: row.string(3),
            planCandidates: candidates,
            modelProvenance: row.optionalString(5),
            costUSD: row.double(6),
            createdAt: row.date(7) ?? Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Plans

    /// The human-confirmed accept: creates a plan (when `planID` is nil) or
    /// appends a step, in one transaction, with an audit event either way.
    func acceptPlan(
        candidate: BurnBarInboxPlanCandidate,
        pack: String,
        now: Date
    ) throws -> (plan: BurnBarInboxPlan, step: BurnBarInboxPlanStep) {
        try databaseSync {
            // Idempotency across view lifetimes and double-clicks: an accept
            // with the same title+body targeting the same plan (or a fresh
            // plan with the same title) returns the existing rows instead of
            // minting duplicates. Content identity, not client state.
            let duplicateQuery: [Row]
            if let planID = candidate.planID {
                duplicateQuery = try queryRows(
                    """
                    SELECT plan_id, id FROM ai_inbox_plan_steps
                    WHERE plan_id = ? AND title = ? AND body_md = ?
                    LIMIT 1
                    """,
                    [.text(planID), .text(candidate.title), .text(candidate.bodyMarkdown)]
                )
            } else {
                duplicateQuery = try queryRows(
                    """
                    SELECT s.plan_id, s.id FROM ai_inbox_plan_steps s
                    JOIN ai_inbox_plans p ON p.id = s.plan_id
                    WHERE p.title = ? AND s.title = ? AND s.body_md = ?
                          AND p.status IN ('proposed', 'active')
                    LIMIT 1
                    """,
                    [.text(candidate.title), .text(candidate.title), .text(candidate.bodyMarkdown)]
                )
            }
            if let existing = duplicateQuery.first,
               let plan = try planLocked(id: existing.string(0)),
               let step = plan.steps.first(where: { $0.id == existing.string(1) }) {
                return (plan, step)
            }

            try execute("BEGIN IMMEDIATE", [])
            do {
                let stamp = Self.string(from: now)
                let planID: String
                if let existing = candidate.planID {
                    guard try planHeadLocked(id: existing) != nil else {
                        throw BurnBarAIInboxStoreError.sqlite("No plan with id \(existing).")
                    }
                    planID = existing
                    try execute(
                        "UPDATE ai_inbox_plans SET updated_at = ?, status = CASE status WHEN 'proposed' THEN 'active' ELSE status END WHERE id = ?",
                        [.text(stamp), .text(planID)]
                    )
                } else {
                    planID = "plan_" + UUID().uuidString.lowercased()
                    try execute(
                        """
                        INSERT INTO ai_inbox_plans(id, title, horizon, pack, status, summary_md, created_at, updated_at, origin_fingerprint)
                        VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?)
                        """,
                        [
                            .text(planID),
                            .text(candidate.title),
                            .text(candidate.horizon.rawValue),
                            .text(pack),
                            .text(candidate.bodyMarkdown),
                            .text(stamp),
                            .text(stamp),
                            .optionalText(candidate.evidenceIDs.first.flatMap(Self.fingerprintFromEvidence))
                        ]
                    )
                }

                let ordinal = try queryRows(
                    "SELECT COALESCE(MAX(ordinal), 0) + 1 FROM ai_inbox_plan_steps WHERE plan_id = ?",
                    [.text(planID)]
                ).first?.int(0) ?? 1

                let stepID = "step_" + UUID().uuidString.lowercased()
                let evidenceJSON = String(
                    data: try Self.jsonEncoder.encode(candidate.evidenceIDs),
                    encoding: .utf8
                )
                try execute(
                    """
                    INSERT INTO ai_inbox_plan_steps(id, plan_id, ordinal, title, body_md, status, evidence_ids_json, inbox_fingerprint, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, 'accepted', ?, ?, ?, ?)
                    """,
                    [
                        .text(stepID),
                        .text(planID),
                        .int(ordinal),
                        .text(candidate.title),
                        .text(candidate.bodyMarkdown),
                        .optionalText(evidenceJSON),
                        .optionalText(candidate.evidenceIDs.first.flatMap(Self.fingerprintFromEvidence)),
                        .text(stamp),
                        .text(stamp)
                    ]
                )
                try appendPlanEventLocked(
                    planID: planID,
                    stepID: stepID,
                    event: "accepted",
                    detail: ["pack": pack, "ordinal": "\(ordinal)"],
                    now: now
                )
                try execute("COMMIT", [])

                guard let plan = try plan(id: planID),
                      let step = plan.steps.first(where: { $0.id == stepID }) else {
                    throw BurnBarAIInboxStoreError.sqlite("Accepted plan row did not read back.")
                }
                return (plan, step)
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    func plans(statuses: [BurnBarInboxPlanStatus], limit: Int) throws -> [BurnBarInboxPlan] {
        try databaseSync {
            let effective = statuses.isEmpty
                ? [BurnBarInboxPlanStatus.active, .proposed]
                : statuses
            let placeholders = effective.map { _ in "?" }.joined(separator: ", ")
            let rows = try queryRows(
                """
                SELECT id FROM ai_inbox_plans
                WHERE status IN (\(placeholders))
                ORDER BY updated_at DESC
                LIMIT ?
                """,
                effective.map { .text($0.rawValue) } + [.int(max(1, limit))]
            )
            return try rows.compactMap { try planLocked(id: $0.string(0)) }
        }
    }

    func plan(id: String) throws -> BurnBarInboxPlan? {
        try databaseSync { try planLocked(id: id) }
    }

    private func planHeadLocked(id: String) throws -> Row? {
        try queryRows(
            """
            SELECT id, title, horizon, pack, status, summary_md, created_at, updated_at,
                   origin_fingerprint, memory_id, pensieve_vector_id, grade_avg
            FROM ai_inbox_plans WHERE id = ? LIMIT 1
            """,
            [.text(id)]
        ).first
    }

    private func planLocked(id: String) throws -> BurnBarInboxPlan? {
        guard let head = try planHeadLocked(id: id) else { return nil }
        let stepRows = try queryRows(
            """
            SELECT id, plan_id, parent_step_id, ordinal, title, body_md, status, next_move_md,
                   evidence_ids_json, mission_id, followup_id, inbox_fingerprint, grade,
                   grade_note_md, graded_at, created_at, updated_at, completed_at
            FROM ai_inbox_plan_steps WHERE plan_id = ? ORDER BY ordinal ASC
            """,
            [.text(id)]
        )
        let steps = stepRows.compactMap(Self.planStep(from:))
        return BurnBarInboxPlan(
            id: head.string(0),
            title: head.string(1),
            horizon: BurnBarInboxPlanHorizon(rawValue: head.string(2)) ?? .week,
            pack: head.string(3),
            status: BurnBarInboxPlanStatus(rawValue: head.string(4)) ?? .proposed,
            summaryMarkdown: head.string(5),
            createdAt: head.date(6) ?? Date(timeIntervalSince1970: 0),
            updatedAt: head.date(7) ?? Date(timeIntervalSince1970: 0),
            originFingerprint: head.optionalString(8),
            memoryID: head.optionalString(9),
            pensieveVectorID: head.optionalString(10),
            gradeAverage: head.optionalString(11).flatMap(Double.init),
            steps: steps
        )
    }

    private static func planStep(from row: Row) -> BurnBarInboxPlanStep? {
        var evidence: [String] = []
        if let json = row.optionalString(8), let data = json.data(using: .utf8) {
            evidence = (try? jsonDecoder.decode([String].self, from: data)) ?? []
        }
        return BurnBarInboxPlanStep(
            id: row.string(0),
            planID: row.string(1),
            parentStepID: row.optionalString(2),
            ordinal: row.int(3),
            title: row.string(4),
            bodyMarkdown: row.string(5),
            status: BurnBarInboxPlanStepStatus(rawValue: row.string(6)) ?? .proposed,
            nextMoveMarkdown: row.optionalString(7),
            evidenceIDs: evidence,
            missionID: row.optionalString(9),
            followupID: row.optionalString(10),
            inboxFingerprint: row.optionalString(11),
            grade: row.optionalString(12).flatMap(Int.init),
            gradeNoteMarkdown: row.optionalString(13),
            gradedAt: row.date(14),
            createdAt: row.date(15) ?? Date(timeIntervalSince1970: 0),
            updatedAt: row.date(16) ?? Date(timeIntervalSince1970: 0),
            completedAt: row.date(17)
        )
    }

    /// Status transition + mission/followup binding. Terminal statuses stamp
    /// `completed_at`; every change writes an audit event.
    func updatePlanStep(
        stepID: String,
        status: BurnBarInboxPlanStepStatus?,
        missionID: String?,
        followupID: String?,
        now: Date
    ) throws -> BurnBarInboxPlanStep {
        try databaseSync {
            try execute("BEGIN IMMEDIATE", [])
            do {
                guard let existing = try queryRows(
                    "SELECT plan_id, status FROM ai_inbox_plan_steps WHERE id = ? LIMIT 1",
                    [.text(stepID)]
                ).first else {
                    throw BurnBarAIInboxStoreError.sqlite("No plan step with id \(stepID).")
                }
                let planID = existing.string(0)
                let stamp = Self.string(from: now)
                let newStatus = status?.rawValue
                let isTerminal = status.map { [.landed, .failed, .killed].contains($0) } ?? false

                // Auto-seed grade on terminal outcome so ungraded steps still
                // feed the compounding loop ("landed" is evidence, "failed" is
                // evidence). The user's explicit `plans.grade` overwrites this.
                let seededGrade: Int?
                switch status {
                case .landed: seededGrade = 85
                case .failed: seededGrade = 25
                default: seededGrade = nil
                }

                try execute(
                    """
                    UPDATE ai_inbox_plan_steps SET
                        status = COALESCE(?, status),
                        mission_id = COALESCE(?, mission_id),
                        followup_id = COALESCE(?, followup_id),
                        completed_at = CASE WHEN ? THEN ? ELSE completed_at END,
                        grade = COALESCE(grade, ?),
                        graded_at = CASE WHEN grade IS NULL AND ? IS NOT NULL THEN ? ELSE graded_at END,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    [
                        .optionalText(newStatus),
                        .optionalText(missionID),
                        .optionalText(followupID),
                        .int(isTerminal ? 1 : 0),
                        .text(stamp),
                        seededGrade.map(Bind.int) ?? .null,
                        seededGrade.map(Bind.int) ?? .null,
                        .text(stamp),
                        .text(stamp),
                        .text(stepID)
                    ]
                )
                if seededGrade != nil {
                    try execute(
                        """
                        UPDATE ai_inbox_plans SET
                            grade_avg = (SELECT AVG(grade) FROM ai_inbox_plan_steps WHERE plan_id = ? AND grade IS NOT NULL)
                        WHERE id = ?
                        """,
                        [.text(planID), .text(planID)]
                    )
                }
                try execute(
                    "UPDATE ai_inbox_plans SET updated_at = ? WHERE id = ?",
                    [.text(stamp), .text(planID)]
                )
                var detail: [String: String] = [:]
                if let newStatus { detail["status"] = newStatus }
                if let missionID { detail["mission_id"] = missionID }
                if let followupID { detail["followup_id"] = followupID }
                try appendPlanEventLocked(
                    planID: planID,
                    stepID: stepID,
                    event: "step_updated",
                    detail: detail,
                    now: now
                )
                try execute("COMMIT", [])
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
            guard let step = try stepLocked(id: stepID) else {
                throw BurnBarAIInboxStoreError.sqlite("Updated step did not read back.")
            }
            return step
        }
    }

    /// Writes a grade (clamped 0–100), refreshes the plan's rolling average,
    /// and audits the event. Returns the step and the new average.
    func gradePlanStep(
        stepID: String,
        grade: Int,
        noteMarkdown: String?,
        now: Date
    ) throws -> (step: BurnBarInboxPlanStep, planAverage: Double?) {
        try databaseSync {
            try execute("BEGIN IMMEDIATE", [])
            do {
                guard let existing = try queryRows(
                    "SELECT plan_id FROM ai_inbox_plan_steps WHERE id = ? LIMIT 1",
                    [.text(stepID)]
                ).first else {
                    throw BurnBarAIInboxStoreError.sqlite("No plan step with id \(stepID).")
                }
                let planID = existing.string(0)
                let clamped = min(max(0, grade), 100)
                let stamp = Self.string(from: now)
                try execute(
                    """
                    UPDATE ai_inbox_plan_steps SET grade = ?, grade_note_md = ?, graded_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    [.int(clamped), .optionalText(noteMarkdown), .text(stamp), .text(stamp), .text(stepID)]
                )
                try execute(
                    """
                    UPDATE ai_inbox_plans SET
                        grade_avg = (SELECT AVG(grade) FROM ai_inbox_plan_steps WHERE plan_id = ? AND grade IS NOT NULL),
                        updated_at = ?
                    WHERE id = ?
                    """,
                    [.text(planID), .text(stamp), .text(planID)]
                )
                try appendPlanEventLocked(
                    planID: planID,
                    stepID: stepID,
                    event: "graded",
                    detail: ["grade": "\(clamped)"],
                    now: now
                )
                try execute("COMMIT", [])

                guard let step = try stepLocked(id: stepID) else {
                    throw BurnBarAIInboxStoreError.sqlite("Graded step did not read back.")
                }
                let average = try queryRows(
                    "SELECT grade_avg FROM ai_inbox_plans WHERE id = ? LIMIT 1",
                    [.text(planID)]
                ).first?.optionalString(0).flatMap(Double.init)
                return (step, average)
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    private func stepLocked(id: String) throws -> BurnBarInboxPlanStep? {
        try queryRows(
            """
            SELECT id, plan_id, parent_step_id, ordinal, title, body_md, status, next_move_md,
                   evidence_ids_json, mission_id, followup_id, inbox_fingerprint, grade,
                   grade_note_md, graded_at, created_at, updated_at, completed_at
            FROM ai_inbox_plan_steps WHERE id = ? LIMIT 1
            """,
            [.text(id)]
        ).first.flatMap(Self.planStep(from:))
    }

    private func appendPlanEventLocked(
        planID: String,
        stepID: String?,
        event: String,
        detail: [String: String],
        now: Date
    ) throws {
        let detailJSON = detail.isEmpty
            ? nil
            : String(data: try Self.jsonEncoder.encode(detail), encoding: .utf8)
        try execute(
            """
            INSERT INTO ai_inbox_plan_events(id, plan_id, step_id, event, detail_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .text("evt_" + UUID().uuidString.lowercased()),
                .text(planID),
                .optionalText(stepID),
                .text(event),
                .optionalText(detailJSON),
                .text(Self.string(from: now))
            ]
        )
    }

    /// Best-effort inbox fingerprint recovery from an evidence id, so a plan
    /// born from an item links back to its thread.
    private static func fingerprintFromEvidence(_ evidenceID: String) -> String? {
        evidenceID.hasPrefix("item:") ? String(evidenceID.dropFirst(5)) : nil
    }

    // MARK: - Standing commitments

    /// Active plans + exported approved snippets, rendered as one line each for
    /// synthesis context. This is the compounding loop's read side.
    func standingCommitments(limit: Int, now: Date) throws -> [BurnBarFounderLens.StandingCommitment] {
        try databaseSync {
            var commitments: [BurnBarFounderLens.StandingCommitment] = []

            let planRows = try queryRows(
                """
                SELECT p.id, p.title, p.status, p.grade_avg,
                       (SELECT title FROM ai_inbox_plan_steps
                        WHERE plan_id = p.id AND status IN ('accepted', 'in_progress')
                        ORDER BY ordinal ASC LIMIT 1)
                FROM ai_inbox_plans p
                WHERE p.status = 'active'
                ORDER BY p.updated_at DESC
                LIMIT ?
                """,
                [.int(max(1, limit))]
            )
            for row in planRows {
                let planID = row.string(0)
                var parts = ["Plan \(planID) [\(row.string(2))]: \(row.string(1))"]
                if let next = row.optionalString(4), next.isEmpty == false {
                    parts.append("next: \(next)")
                }
                if let avg = row.optionalString(3).flatMap(Double.init) {
                    parts.append("grade \(Int(avg.rounded()))")
                }
                commitments.append(
                    BurnBarFounderLens.StandingCommitment(
                        provenance: "ai-inbox:plan:\(planID)",
                        summary: parts.joined(separator: " — ")
                    )
                )
            }

            let remaining = limit - commitments.count
            if remaining > 0 {
                let memoryRows = try queryRows(
                    """
                    SELECT memory_id, provenance, snippet_md
                    FROM ai_inbox_memory_export
                    ORDER BY approved_at DESC
                    LIMIT ?
                    """,
                    [.int(remaining)]
                )
                for row in memoryRows {
                    commitments.append(
                        BurnBarFounderLens.StandingCommitment(
                            provenance: row.string(1),
                            summary: "Approved fact: \(row.string(2))"
                        )
                    )
                }
            }
            return commitments
        }
    }

    // MARK: - Memory export

    /// Full-set replacement (revocation by omission — see the export contract).
    func replaceMemoryExport(entries: [BurnBarInboxMemoryExportEntry], now: Date) throws -> Int {
        try databaseSync {
            try execute("BEGIN IMMEDIATE", [])
            do {
                try execute("DELETE FROM ai_inbox_memory_export", [])
                let stamp = Self.string(from: now)
                for entry in entries {
                    try execute(
                        """
                        INSERT INTO ai_inbox_memory_export(memory_id, provenance, snippet_md, approved_at, exported_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        [
                            .text(entry.memoryID),
                            .text(entry.provenance),
                            .text(entry.snippetMarkdown),
                            .text(Self.string(from: entry.approvedAt)),
                            .text(stamp)
                        ]
                    )
                }
                try execute("COMMIT", [])
                return entries.count
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }
}
