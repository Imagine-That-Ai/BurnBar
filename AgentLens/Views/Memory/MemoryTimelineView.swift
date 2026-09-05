import SwiftUI

/// B8: one memory's project-scoped revision timeline — ordered events, the
/// device that wrote each revision, and when the memory last helped.
///
/// Not yet mounted: the engine's `burnbar_memory_timeline` read API (the
/// contract `MemoryTimelineModel` documents) is the missing half. The view is
/// driven entirely by its model, so wiring it is a call site, not a rewrite.
struct MemoryTimelineView: View {
    let model: MemoryTimelineModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.md)

            Divider().background(DesignSystem.Colors.border.opacity(0.6))

            if model.isLoading {
                loadingView
            } else if model.isRefused {
                refusedView
            } else if let error = model.errorMessage {
                errorView(error)
            } else if model.revisions.isEmpty {
                emptyView
            } else {
                revisionsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background)
        .task {
            await model.load()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
                Text("Memory timeline")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                Spacer()

                if let source = model.lastHelpedSource, let date = model.lastHelpedAt {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9))
                        Text("Last helped: \(date) (\(source))")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(DesignSystem.Colors.ember.opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            Text("Revisions & Attribution")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Memory ID: \(model.memoryID)")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private var loadingView: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Spacer()
            ProgressView()
            Text("Loading timeline...")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
        }
    }

    private var refusedView: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(DesignSystem.Colors.amber)
            Text("Access Refused")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("This memory belongs to another project and cannot be inspected from the current scope (\(model.refusalCode ?? "FOREIGN_PROJECT")).")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.xl)
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(DesignSystem.Colors.amber)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Spacer()
            Image(systemName: "clock")
                .font(.system(size: 24))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("No revisions recorded")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer()
        }
    }

    private var revisionsList: some View {
        ScrollView {
            LazyVStack(spacing: DesignSystem.Spacing.md) {
                ForEach(model.revisions) { revision in
                    revisionCard(revision)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private func revisionCard(_ rev: MemoryTimelineModel.RevisionItem) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text("#\(rev.seq)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(DesignSystem.Colors.border.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(rev.displayEvent)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                if let device = rev.writerDevice {
                    HStack(spacing: 3) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 9))
                        Text(device)
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(DesignSystem.Colors.border.opacity(0.2))
                    .clipShape(Capsule())
                }

                Spacer()

                Text(rev.timestamp)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            if let after = rev.after {
                Text(after)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .padding(.vertical, 2)
            }

            if let before = rev.before {
                HStack(alignment: .top, spacing: 4) {
                    Text("Before:")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(before)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }

            HStack(spacing: 4) {
                Text(rev.actor)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                if let metaSummary = rev.metaSummary {
                    Text("· \(metaSummary)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 1)
        )
    }
}
