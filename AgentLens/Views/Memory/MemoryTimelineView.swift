import SwiftUI

/// B8: one memory's history — the ordered events recorded against it, its
/// lineage, and when it was last touched.
///
/// The view is deliberately explicit about WHICH history it is showing. The
/// engine keeps revision bodies; the app keeps an audit ledger. A reader who
/// cannot tell them apart would read a nil `before`/`after` as "nothing
/// changed", so the footer says the contents were never retained and the header
/// names the source.
struct MemoryTimelineView: View {
    let model: MemoryTimelineModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header

            if model.isLoading {
                loadingView
            } else if model.isRefused {
                refusedView
            } else if let error = model.errorMessage {
                errorView(error)
            } else if model.isNotFound {
                notFoundView
            } else if model.revisions.isEmpty {
                emptyView
            } else {
                revisionsList
            }

            // M4: the provenance line belongs to every state that got an answer.
            // "Nothing has happened to this memory yet" and "no record of this
            // memory" are the two readings most likely to be mistaken for the
            // engine's verdict, and they were the two states that carried no
            // source at all.
            if let truncationNote = model.truncationNote {
                footnote(truncationNote)
            }
            if let provenanceNote = model.provenanceNote {
                footnote(provenanceNote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.load() }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
                Text("History")
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                Spacer(minLength: 0)

                if let source = model.lastHelpedSource, let date = model.lastHelpedAt {
                    Text("Last recorded: \(date) (\(source))")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.ember)
                        .lineLimit(1)
                }
            }

            if let device = model.writerDevice {
                Label("Arrived from \(device)", systemImage: "laptopcomputer")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            if let lineage = lineageSummary {
                Text(lineage)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

    /// `valid_from` / `valid_to` / `superseded_by`, rendered only where the row
    /// actually carries them.
    private var lineageSummary: String? {
        var parts: [String] = []
        if let validFrom = model.validFrom { parts.append("Valid from \(validFrom)") }
        if let validTo = model.validTo { parts.append("retired \(validTo)") }
        if let supersededBy = model.supersededBy { parts.append("superseded by \(supersededBy)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var loadingView: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text("Loading history…")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private var refusedView: some View {
        noticeRow(
            icon: "lock.shield",
            tint: DesignSystem.Colors.amber,
            text: "This memory belongs to another project and cannot be inspected from the current scope (\(model.code ?? "FOREIGN_PROJECT"))."
        )
    }

    private func errorView(_ message: String) -> some View {
        noticeRow(
            icon: "exclamationmark.triangle",
            tint: DesignSystem.Colors.amber,
            text: message
        )
    }

    /// Distinct from `emptyView` on purpose: "nothing here knows this memory" is
    /// not "this memory has never been touched".
    private var notFoundView: some View {
        noticeRow(
            icon: "questionmark.circle",
            tint: DesignSystem.Colors.textMuted,
            text: "No record of this memory in the local ledger."
        )
    }

    private var emptyView: some View {
        noticeRow(
            icon: "clock",
            tint: DesignSystem.Colors.textMuted,
            text: "Nothing has happened to this memory yet."
        )
    }

    private func noticeRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var revisionsList: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            ForEach(model.revisions) { revision in
                revisionRow(revision)
            }
        }
    }

    private func revisionRow(_ rev: MemoryTimelineModel.RevisionItem) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Text("#\(rev.seq)")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(minWidth: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DesignSystem.Spacing.xxs) {
                    Text(rev.displayEvent)
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(rev.actor)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    if let device = rev.writerDevice {
                        Text("· \(device)")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }

                    Spacer(minLength: 0)

                    Text(rev.ts)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                if let meta = rev.metaSummary {
                    Text(meta)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The lines that qualify the result itself — which ledger answered, and
    /// whether the list is the whole of it. Both are generated on the model so
    /// they are assertable without a snapshot.
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
