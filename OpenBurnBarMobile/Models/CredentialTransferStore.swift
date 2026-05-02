import Foundation
import OpenBurnBarCore

@Observable @MainActor
final class CredentialTransferStore {
    private let reader: CloudReader
    private let escrowGateway: EscrowGateway
    private(set) var available: [AvailableEnvelope] = []
    private(set) var unsupported: [UnsupportedEnvelope] = []
    private(set) var history: [ImportHistoryEntry] = []
    private(set) var isLoading = false
    private(set) var lastError: CloudErrorClassification?
    private(set) var importingEnvelopeID: String?
    private(set) var importStage: ImportStage = .idle

    init(reader: CloudReader = LiveCloudReader(), escrowGateway: EscrowGateway = LiveEscrowGateway()) {
        self.reader = reader; self.escrowGateway = escrowGateway
        escrowGateway.observeEnvelopes { [weak self] in
            guard let self else { return }
            Task { await self.load() }
        }
    }

    var availableCount: Int { available.count }
    var revokedCount: Int { history.filter { $0.status == .revoked }.count }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            available = try await reader.loadAvailableEnvelopes()
            unsupported = try await reader.loadUnsupportedEnvelopes()
            history = try await reader.loadImportHistory()
            lastError = nil
        }
        catch let CloudGatewayError.classified(c) { lastError = c }
        catch { lastError = .other(message: error.localizedDescription) }
    }

    func startImport(_ envelope: AvailableEnvelope) async {
        importingEnvelopeID = envelope.id; importStage = .downloading
        await escrowGateway.runImport(envelope: envelope) { [weak self] stage in self?.importStage = stage }
        if case .validated = importStage { await load(); importingEnvelopeID = nil }
    }

    func resetImport() { importingEnvelopeID = nil; importStage = .idle }
}
