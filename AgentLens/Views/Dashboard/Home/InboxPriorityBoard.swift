import SwiftUI
import OpenBurnBarInboxModels

// MARK: - Inbox priority board
//
// Three columns by priority band: what needs you now, what needs you today,
// and everything else.
//
// Cards are built from lighter parts rather than reusing `InboxRowView`: that
// row carries a twelve-field `InboxRowActions`, drag-and-drop, drop targeting,
// category chips and a selection model — all of which exist to serve the list,
// and none of which a board column needs. Reusing it would mean threading
// twelve closures through a surface that only ever opens an item.
//
// The grouping vocabulary (which priority is "Urgent", what colour it takes) is
// `InboxPresentation`'s, not this file's — a new detector should get coherent
// treatment here by adding one case there.

struct InboxPriorityBoard: View {
    let model: InboxModel
    let ink: BackdropInk
    let onOpenItem: (String) -> Void

    /// The three bands. `p1` alone is urgent; `p2` is today; `p3`+ is the tail,
    /// grouped so the board never grows a fourth column nobody reads.
    private enum Column: String, CaseIterable, Identifiable {
        case urgent, today, later
        var id: String { rawValue }

        var title: String {
            switch self {
            case .urgent: return "URGENT"
            case .today:  return "TODAY"
            case .later:  return "LATER"
            }
        }

        func contains(_ priority: BurnBarInboxPriority) -> Bool {
            switch self {
            case .urgent: return priority == .p1
            case .today:  return priority == .p2
            case .later:  return priority == .p3 || priority == .p4
            }
        }

        var tint: Color {
            switch self {
            case .urgent: return DesignSystem.Colors.error
            case .today:  return DesignSystem.Colors.amber
            case .later:  return DesignSystem.Colors.whimsy
            }
        }
    }

    var body: some View {
        Group {
            if model.visibleRows.isEmpty {
                InboxEmptyState(
                    icon: "checkmark.seal",
                    title: "Nothing needs you",
                    message: "OpenBurnBar is watching your sessions, workspaces, and GitHub. Anything worth your attention shows up here.",
                    ink: ink
                )
            } else {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    ForEach(Column.allCases) { column in
                        columnView(column)
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private func columnView(_ column: Column) -> some View {
        let rows = model.visibleRows.filter { column.contains($0.summary.priority) }

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Circle()
                    .fill(column.tint)
                    .frame(width: 6, height: 6)
                Text(column.title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(0.8)
                    .foregroundStyle(ink.secondary)
                Text("\(rows.count)")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(ink.subtle)
            }

            if rows.isEmpty {
                // A column with nothing in it is good news, so say so rather
                // than leaving a blank that reads as a loading failure.
                Text(column == .urgent ? "Clear" : "Nothing here")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(ink.subtle)
                    .padding(.vertical, DesignSystem.Spacing.xs)
            } else {
                ScrollView {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(rows) { row in
                            card(row, tint: column.tint)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ row: ControlPlaneStore.AIInboxRow, tint: Color) -> some View {
        Button { onOpenItem(row.id) } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: InboxPresentation.icon(for: row.summary.kind))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))
                    Text(InboxPresentation.kindLabel(row.summary.kind))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(ink.subtle)
                    Spacer(minLength: 0)
                    if row.isUnread {
                        Circle().fill(tint).frame(width: 5, height: 5)
                    }
                }

                Text(row.summary.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(ink.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let project = row.summary.projectName, project.isEmpty == false {
                    Text(project)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(ink.subtle)
                        .lineLimit(1)
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .strokeBorder(ink.hairline.opacity(0.5), lineWidth: 0.75)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(OBBAccessibilityID.inboxRow(row.id))
    }
}
