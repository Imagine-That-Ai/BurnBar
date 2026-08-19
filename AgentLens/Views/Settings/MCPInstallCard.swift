import SwiftUI

// MARK: - MCP Install Card
//
// The one-click half of T0.4: give the coding agents the user already runs
// OpenBurnBar's memory surface, without hand-editing JSON. Each row is a
// client; the state is probed live from the client's real config file, the
// disclosure line names the exact file the button will modify, and when no
// server can be resolved on this Mac the card says WHY instead of writing a
// config entry that points at nothing.

struct MCPInstallCard: View {
    struct RowState: Identifiable, Equatable {
        let target: MCPClientWiringTarget
        var isWired: Bool
        var lastError: String?

        var id: String { target.rawValue }
    }

    private let wiring = MCPClientWiring()
    @State private var rows: [RowState] = []
    @State private var resolution: MCPServerLaunchResolver.Resolution?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Text("Agent memory (MCP)")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text("Give your coding agents OpenBurnBar's memory: search past sessions, recall approved facts, resume work — served locally from this Mac.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let resolution, resolution.launch == nil {
                Text(resolution.unavailabilityReason ?? "The OpenBurnBar MCP server was not found on this Mac.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(rows) { row in
                clientRow(row)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.surface)
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func clientRow(_ row: RowState) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.target.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(displayPath(wiring.configURL(for: row.target)))
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: DesignSystem.Spacing.sm)
                if row.isWired {
                    Button("Remove") { unwire(row.target) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Install") { wire(row.target) }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.blaze)
                        .controlSize(.small)
                        .disabled(resolution?.launch == nil)
                }
            }
            if let error = row.lastError {
                Text(error)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        resolution = MCPServerLaunchResolver.resolve()
        rows = MCPClientWiringTarget.allCases.map { target in
            RowState(target: target, isWired: wiring.isWired(target: target), lastError: nil)
        }
    }

    private func wire(_ target: MCPClientWiringTarget) {
        guard let launch = resolution?.launch else { return }
        mutate(target) { try wiring.wire(target: target, launch: launch) }
    }

    private func unwire(_ target: MCPClientWiringTarget) {
        mutate(target) { try wiring.unwire(target: target) }
    }

    private func mutate(_ target: MCPClientWiringTarget, _ operation: () throws -> MCPClientWiringChange) {
        do {
            _ = try operation()
            refresh()
        } catch {
            if let index = rows.firstIndex(where: { $0.target == target }) {
                rows[index].lastError = error.localizedDescription
            }
        }
    }

    /// `~`-relative rendering so the disclosure reads like the docs do.
    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
