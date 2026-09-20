import SwiftUI
import OpenBurnBarCore

// MARK: - Agents overflow
//
// Compact column keeps identity + thread + switcher on screen. Everything
// else that already lives in Hermes Square is one tap from this sheet.

struct HermesSquareAgentsOverflowSheet: View {
    let missionTiles: [MissionConsoleActiveTile]
    let rollbackSessions: [(key: String, value: [RollbackSnapshot])]
    let resumeSessions: [CLIAgentSessionRecord]
    let onSelect: (HermesSquareAgentsColumnRouting.OverflowDestination) -> Void
    let onOpenMission: (String) -> Void
    let onResume: (CLIAgentSessionRecord) -> Void
    let onRollback: (String, RollbackScope) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Agent") {
                    overflowRow(.switcher, title: "Switch agent", systemImage: "arrow.left.arrow.right")
                }

                Section("Reachable") {
                    overflowRow(.wand, title: "The Wand", systemImage: "wand.and.stars")
                    overflowRow(.missions, title: "Missions", systemImage: "bolt.fill")
                    overflowRow(.resumeHandoff, title: "Resume / Handoff", systemImage: "laptopcomputer.and.arrow.down")
                    overflowRow(.capabilityGrants, title: "Capability grants", systemImage: "hand.raised")
                    overflowRow(.rollback, title: "Rollback", systemImage: "arrow.uturn.backward")
                }

                Section("More") {
                    overflowRow(.search, title: "Search", systemImage: "magnifyingglass")
                    overflowRow(.pinned, title: "Pinned agents", systemImage: "pin.fill")
                    overflowRow(.projectMemory, title: "Project memory", systemImage: "book.closed")
                    overflowRow(.subscriptions, title: "Subscriptions", systemImage: "tray.fill")
                    overflowRow(.discover, title: "Discover", systemImage: "sparkles.rectangle.stack.fill")
                    overflowRow(.voice, title: "Voice command", systemImage: "mic.circle.fill")
                }

                if !missionTiles.isEmpty {
                    Section("Live missions") {
                        ForEach(missionTiles) { tile in
                            Button {
                                dismiss()
                                onOpenMission(tile.id)
                            } label: {
                                HermesSquareMissionTile(tile: tile)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                        }
                    }
                }

                if !resumeSessions.isEmpty {
                    Section("Resume on Mac") {
                        ForEach(resumeSessions.prefix(8), id: \.id) { session in
                            Button {
                                dismiss()
                                onResume(session)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title.isEmpty ? session.agent.displayName : session.title)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                                    Text(session.agent.displayName)
                                        .font(.caption)
                                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                                }
                            }
                        }
                    }
                }

                if !rollbackSessions.isEmpty {
                    Section("Rollback") {
                        ForEach(rollbackSessions, id: \.key) { sessionID, snapshots in
                            RollbackCardView(sessionID: sessionID, snapshots: snapshots) { scope in
                                onRollback(sessionID, scope)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .navigationTitle("Agents overflow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func overflowRow(
        _ destination: HermesSquareAgentsColumnRouting.OverflowDestination,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            dismiss()
            onSelect(destination)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier("agents.overflow.\(destination.rawValue)")
    }
}
