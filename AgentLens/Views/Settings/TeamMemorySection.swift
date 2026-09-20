import SwiftUI

// MARK: - Team memory (Settings → Privacy), memory program D16 / P22, PR 4
//
// The member-facing surface of the fourth blind lane. It sits beside
// `MemoryCloudModelsSection` and behaves like it: Data Vault gated, off by
// default, and honest in the copy about what the server can see.
//
// THREE THINGS THIS SECTION DELIBERATELY DOES NOT DO.
//
//  1. It never writes a roster. `firestore.rules` denies every client write to
//     `team_rosters/**`, so the member list here is a READ and every mutation is
//     a callable. An optimistic local edit would be a lie the next refresh
//     erases.
//  2. It never offers "join without history". A joiner is issued an envelope for
//     every RETAINED key generation before the roster promotes them, so joining
//     grants the whole history — Semantic A — and the confirmation says so
//     verbatim rather than burying it.
//  3. It never claims leaving retracts anything. Removal cuts access at the next
//     read or write and marks the team for rotation; neither reaches a device
//     that already synced — Semantic B, also verbatim.
struct TeamMemorySection: View {
    // NO `SettingsManager` HERE (PR 4 review L2). Every setting this section
    // touches — the per-team consent lever, the personal gate, the fleet
    // ceiling — is reached through `TeamMemorySectionModel`'s injected
    // closures, which is what makes the model testable without a settings
    // store. A `@Bindable` the body never read only forced the call site to
    // thread one through.
    var model: TeamMemorySectionModel

    @State private var showCreateSheet = false
    @State private var showJoinSheet = false
    @State private var newTeamName = ""
    @State private var inviteToken = ""
    @State private var joinTeamID = ""
    @State private var inviteEmail: [String: String] = [:]
    @State private var pendingJoin: (teamID: String, token: String)?
    @State private var pendingLeaveTeamID: String?
    @State private var pendingRemoval: (teamID: String, uid: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header

            if model.rows.isEmpty {
                Text(TeamMemoryCopy.emptyTeamsNotice)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            } else {
                ForEach(model.rows) { row in
                    teamCard(row)
                }
            }

            if let errorMessage = model.errorMessage {
                notice(errorMessage)
            }

            if let token = model.lastIssuedInviteToken {
                // Shown ONCE. The server stores only `sha256(token)` and cannot
                // hand it back, so this is the only moment the admin can copy it.
                Text("Invite token (copy it now — it is never shown again): \(token)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(TeamMemoryCopy.settingsFootnote)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsAnchor(SettingsAnchor.indexingTeamMemory)
        .task { await model.refresh() }
        .sheet(isPresented: $showCreateSheet) { createSheet }
        .sheet(isPresented: $showJoinSheet) { joinSheet }
        .alert(
            TeamMemoryCopy.joinAlertTitle,
            isPresented: Binding(get: { pendingJoin != nil }, set: { if !$0 { pendingJoin = nil } })
        ) {
            Button(TeamMemoryCopy.cancelAction, role: .cancel) { pendingJoin = nil }
            Button(TeamMemoryCopy.joinConfirmAction) {
                guard let join = pendingJoin else { return }
                pendingJoin = nil
                Task { await model.acceptInvite(teamID: join.teamID, token: join.token) }
            }
        } message: {
            Text(TeamMemoryCopy.joinSemanticA)
        }
        .alert(
            TeamMemoryCopy.leaveAlertTitle,
            isPresented: Binding(get: { pendingLeaveTeamID != nil }, set: { if !$0 { pendingLeaveTeamID = nil } })
        ) {
            Button(TeamMemoryCopy.cancelAction, role: .cancel) { pendingLeaveTeamID = nil }
            Button(TeamMemoryCopy.leaveConfirmAction, role: .destructive) {
                guard let teamID = pendingLeaveTeamID else { return }
                pendingLeaveTeamID = nil
                Task { await model.leaveTeam(teamID: teamID) }
            }
        } message: {
            Text(TeamMemoryCopy.leaveSemanticB)
        }
        .alert(
            TeamMemoryCopy.alertTitle,
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button(TeamMemoryCopy.cancelAction, role: .cancel) { pendingRemoval = nil }
            Button(TeamMemoryCopy.alertDestructiveAction, role: .destructive) {
                guard let removal = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await model.removeMember(teamID: removal.teamID, targetUid: removal.uid) }
            }
        } message: {
            Text(TeamMemoryCopy.removeMemberDetail)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(TeamMemoryCopy.sectionTitle)
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text(TeamMemoryCopy.sectionSubtitle)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button(TeamMemoryCopy.createTeamAction) { showCreateSheet = true }
                    .buttonStyle(.bordered)
                Button(TeamMemoryCopy.joinWithTokenAction) { showJoinSheet = true }
                    .buttonStyle(.bordered)
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    // MARK: One team

    @ViewBuilder
    private func teamCard(_ row: TeamMemorySectionModel.TeamRow) -> some View {
        let detail = row.detail
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text(detail.name)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
                Button(TeamMemoryCopy.leaveConfirmAction) { pendingLeaveTeamID = detail.teamID }
                    .buttonStyle(.borderless)
                    .font(DesignSystem.Typography.tiny)
            }

            SettingsToggle(
                title: TeamMemoryCopy.syncToggleTitle,
                subtitle: TeamMemoryCopy.syncToggleSubtitle,
                isOn: Binding(
                    get: { row.optedIn },
                    set: { model.setOptIn($0, teamID: detail.teamID) }
                )
            )
            .disabled(!row.availability.isAvailable)

            if let explanation = row.availability.explanation {
                notice(explanation)
            }

            if detail.isMemberPending {
                Text(TeamMemoryCopy.pendingJoinDetail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            keyReadiness(row)

            // THIS team's counters or none (PR 4 review M3). A rotation pass
            // reports on one corpus, and the row for another team must not
            // repeat its numbers.
            ForEach(
                TeamMemorySectionModel.rotationStatusLines(
                    for: detail,
                    progress: model.rotationProgress(forTeamID: detail.teamID)
                ),
                id: \.self
            ) { line in
                Text(line)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            memberList(row)

            if detail.isAdmin {
                adminActions(row)
                rotationConflictRecovery(row)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    /// What THIS Mac holds for the team, and the founder's recovery when the
    /// answer is "not the keys it minted".
    ///
    /// It is rendered for every state including the good one. Before the founder
    /// bootstrap and the joiner pickup had callers, EVERY member was in the bad
    /// state and the section said nothing at all — a switch that read available
    /// above a lane that could not seal a single fact. A row that only speaks up
    /// when something is wrong is a row a member cannot use to tell "working"
    /// from "silently doing nothing".
    @ViewBuilder
    private func keyReadiness(_ row: TeamMemorySectionModel.TeamRow) -> some View {
        if let readinessLine = row.keyReadiness.notice {
            if row.keyReadiness == .ready {
                Text(readinessLine)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                notice(readinessLine)
            }
        }
        if model.canFinishTeamSetup(row: row) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(TeamMemoryCopy.finishTeamSetupDetail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(TeamMemoryCopy.finishTeamSetupAction) {
                    Task { await model.finishTeamSetup(teamID: row.detail.teamID) }
                }
                .buttonStyle(.bordered)
                .font(DesignSystem.Typography.caption)
                .disabled(model.isLoading)
            }
        }
    }

    private func memberList(_ row: TeamMemorySectionModel.TeamRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(row.detail.members) { member in
                memberRow(row, member: member)
            }
            Text(TeamMemoryCopy.memberListCaption)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            // Said ONCE per team, not once per pending member, and only to the
            // admin who can act on it: promotion grants the joiner the team's
            // whole history, and the button is not offered without that on
            // screen beside it.
            if row.detail.members.contains(where: { model.canShareTeamKeys(row: row, member: $0) }) {
                Text(TeamMemoryCopy.shareKeysDetail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DesignSystem.Spacing.xs)
            }
        }
    }

    /// One roster row. A non-admin — and an admin looking at their own row —
    /// gets the uid, the role and the status and nothing else: the roster is
    /// server-owned, so every state here is a READ, and a pending member is
    /// shown as pending rather than offered an action the rules would deny.
    @ViewBuilder
    private func memberRow(
        _ row: TeamMemorySectionModel.TeamRow,
        member: TeamRosterDetail.Member
    ) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Text(member.uid)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
            Text("· \(member.role) · \(member.status)")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer(minLength: 0)

            if model.isSharingKeys(teamID: row.detail.teamID, uid: member.uid) {
                Text(TeamMemoryCopy.shareKeysInProgress)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            } else if model.canShareTeamKeys(row: row, member: member) {
                // The join half of design §3(b)2. It goes through
                // `TeamJoinerKeyIssuing`, which runs the whole wrap-then-promote
                // sequence — a UI that called `promoteTeamMember` on its own
                // would be refused by the coverage check, and if it were not,
                // would leave the joiner active-but-blind.
                Button(TeamMemoryCopy.shareKeysAction) {
                    Task { await model.shareTeamKeys(teamID: row.detail.teamID, joinerUid: member.uid) }
                }
                .buttonStyle(.borderless)
                .font(DesignSystem.Typography.tiny)
                // One pass at a time on this Mac: envelope ids are create-only,
                // so two concurrent passes would race for the same documents.
                .disabled(model.sharingKeysForUID != nil)
            }

            // Removing YOURSELF is "Leave", not "Remove": both reach the
            // same callable (`removeTeamMember` accepts a self-leave),
            // but only the leave path clears this Mac's consent and its
            // local team entry, so offering both for the same row would
            // leave one of them lying about what it did.
            if row.detail.isAdmin, member.uid != model.signedInUID {
                Button(TeamMemoryCopy.removeMemberAction) {
                    pendingRemoval = (row.detail.teamID, member.uid)
                }
                .buttonStyle(.borderless)
                .font(DesignSystem.Typography.tiny)
            }
        }
    }

    private func adminActions(_ row: TeamMemorySectionModel.TeamRow) -> some View {
        let teamID = row.detail.teamID
        return HStack(spacing: DesignSystem.Spacing.sm) {
            TextField(
                TeamMemoryCopy.inviteEmailFieldPrompt,
                text: Binding(
                    get: { inviteEmail[teamID] ?? "" },
                    set: { inviteEmail[teamID] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)

            Button(TeamMemoryCopy.inviteMemberAction) {
                let email = inviteEmail[teamID] ?? ""
                inviteEmail[teamID] = ""
                Task { await model.inviteMember(teamID: teamID, email: email) }
            }
            .buttonStyle(.bordered)
            .disabled((inviteEmail[teamID] ?? "").isEmpty)

            Button(TeamMemoryCopy.rotateNowAction) {
                Task { await model.rotateKey(teamID: teamID) }
            }
            .buttonStyle(.bordered)
            .disabled(model.isLoading)
        }
        .font(DesignSystem.Typography.caption)
    }

    /// The recovery from a rotation conflict, shown ONLY after one on THIS team.
    ///
    /// It is a second, separate press and it carries its cost above it: the
    /// generation is recorded unusable on the roster and never used again. The
    /// generic "Rotate Key Now" button stays exactly where it is — retrying that
    /// is what an admin should do for every other rotation failure, and this
    /// button must never be the thing they reach for by habit.
    @ViewBuilder
    private func rotationConflictRecovery(_ row: TeamMemorySectionModel.TeamRow) -> some View {
        if let version = model.rotationConflictVersion(forTeamID: row.detail.teamID) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(TeamMemoryCopy.abandonGenerationDetail(version: version))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(TeamMemoryCopy.abandonGenerationAction) {
                    Task { await model.abandonConflictingGenerationAndRotate(teamID: row.detail.teamID) }
                }
                .buttonStyle(.bordered)
                .disabled(model.isLoading)
            }
        }
    }

    // MARK: Sheets

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(TeamMemoryCopy.createTeamAction)
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
            TextField(TeamMemoryCopy.teamNameFieldPrompt, text: $newTeamName)
                .textFieldStyle(.roundedBorder)
            Text(TeamMemoryCopy.settingsFootnote)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(TeamMemoryCopy.cancelAction) { showCreateSheet = false }
                Spacer()
                Button(TeamMemoryCopy.createTeamAction) {
                    let name = newTeamName
                    newTeamName = ""
                    showCreateSheet = false
                    Task { await model.createTeam(named: name) }
                }
                .disabled(newTeamName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 420)
    }

    private var joinSheet: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(TeamMemoryCopy.joinHeader)
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
            TextField("Team id", text: $joinTeamID)
                .textFieldStyle(.roundedBorder)
            TextField(TeamMemoryCopy.inviteTokenFieldPrompt, text: $inviteToken)
                .textFieldStyle(.roundedBorder)
            Text(TeamMemoryCopy.joinSemanticA)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(TeamMemoryCopy.cancelAction) { showJoinSheet = false }
                Spacer()
                Button(TeamMemoryCopy.joinConfirmAction) {
                    let teamID = joinTeamID
                    let token = inviteToken
                    joinTeamID = ""
                    inviteToken = ""
                    showJoinSheet = false
                    pendingJoin = (teamID, token)
                }
                .disabled(joinTeamID.isEmpty || inviteToken.isEmpty)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 420)
    }

    private func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.warning)
                .padding(.top, 2)
            Text(text)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(DesignSystem.Colors.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
    }
}
