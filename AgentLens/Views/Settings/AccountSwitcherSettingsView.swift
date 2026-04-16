import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Account Switcher Settings View

/// Settings view for managing account switcher profiles.
/// Supports browser profiles (Chrome, Safari) and CLI profiles (Codex, Claude, OpenCode).
///
/// Security properties (VAL-SETTINGS-008):
/// - No cookie/session import or raw credential persistence
/// - Only non-sensitive launch metadata is stored
/// - OAuth boundary messaging is explicit
struct AccountSwitcherSettingsView: View {
    let dataStore: DataStore
    let settingsManager: SettingsManager

    @State var profiles: [SwitcherProfileRecord] = []
    @State var activeProfileID: String?
    @State var activeProfileState: SwitcherActiveProfileState = .init(activeProfileID: nil)
    @State var isLoading = true
    @State var error: String?
    @State var profileForAccountChange: SwitcherProfileRecord?
    @State var reconnectingCLIProfileID: String?
    @State var pendingCLIAccountUpdate: PendingCLIAccountUpdate?
    @State var showingReconnectConfirmation = false
    @State var reconnectDestination: AccountChangeDestination?
    @State var reconnectProfile: SwitcherProfileRecord?
    @State var expandedProviderKeys: Set<String> = []
    @State var connectingProviderKey: String?
    @State var quotaService = ProviderQuotaService.shared
    @Environment(\.colorScheme) var colorScheme

    // Sheet states
    @State var showingCreateSheet = false
    @State var showingEditSheet = false
    @State var showingDeleteConfirmation = false
    @State var profileToEdit: SwitcherProfileRecord?
    @State var profileToDelete: SwitcherProfileRecord?

    // Edit form state
    @State var editFormName = ""
    @State var editFormTargetKind: SwitcherProfileTargetKind = .browser
    @State var editFormBrowserType: SwitcherBrowserProfileType = .chrome
    @State var editFormCLIType: SwitcherCLIProfileType = .claude
    @State var editFormProfileIdentifier = ""
    @State var editFormWorkingDirectory = ""
    @State var editFormAdditionalArgs = ""
    @State var editFormEnvKeys = ""
    @State var editFormValidationError: String?
    @State var editFormDuplicateError: String?
    @State var isSaving = false

    let supportedTargets = ["Google Chrome", "Safari", "Codex", "Claude Code", "OpenCode"]

    struct PendingCLIAccountUpdate: Identifiable {
        let id: String
        let updatedProfile: SwitcherProfileRecord
        let previousAccount: String?
        let detectedAccount: String?
        let canSaveAsNew: Bool
    }

    init(dataStore: DataStore, settingsManager: SettingsManager = .shared) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
    }
}
