import AppKit
import AuthenticationServices
import CryptoKit
@preconcurrency import FirebaseAuth
import FirebaseCore
import FirebaseFunctions
import Foundation
@preconcurrency import GoogleSignIn
import OSLog
import Security

// MARK: - AccountManager

/// Manages Firebase Authentication and device identity.
/// Supports Sign in with Apple and Google. Device UUID is persisted locally in app defaults
/// and migrated from legacy OpenBurnBar/AgentLens defaults keys when present.
@Observable
@MainActor
final class AccountManager {

    static let shared = AccountManager()

    // MARK: - State

    private(set) var isSignedIn = false
    private(set) var userID: String?
    private(set) var userEmail: String?
    private(set) var userDisplayName: String?
    private(set) var currentUser: User?
    private(set) var isAnonymousUser = true
    private(set) var lastOAuthProviderID: String?
    private(set) var lastOAuthToken: String?
    private(set) var lastOAuthEmail: String?
    private(set) var lastOAuthDisplayName: String?
    private(set) var isCloudSyncEnabled = true
    private(set) var isFirebaseAvailable = false

    /// Stable device identifier stored in Keychain.
    let deviceId: String

    // MARK: - Private

    private var authStateListenerHandle: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?
    private var firebaseAuthAccessGroup: String?
    /// Retains `AppleSignInPresentationCoordinator` until Sign in with Apple completes.
    private var appleSignInPresentation: AppleSignInPresentationCoordinator?
    private static let authLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.openburnbar.app",
        category: "AccountManager"
    )

    /// Avoids calling `FirebaseApp.app()` when no default app exists, which can emit noisy logs.
    private static var hasConfiguredFirebaseApp: Bool {
        !(FirebaseApp.allApps ?? [:]).isEmpty
    }

    // MARK: - Init

    init() {
        deviceId = Self.loadOrCreateDeviceId()
        configureFirebase()
    }

    // MARK: - Firebase Setup

    private func configureFirebase() {
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil,
              Self.hasConfiguredFirebaseApp else {
            return
        }
        isFirebaseAvailable = true
        configureFirebaseAuthAccessGroup()
        configureGoogleSignInIfPossible()
        refreshAuthStateSnapshot()
        observeAuthState()
    }

    func onFirebaseConfigured() {
        isFirebaseAvailable = true
        configureFirebaseAuthAccessGroup()
        configureGoogleSignInIfPossible()
        refreshAuthStateSnapshot()
        observeAuthState()
        #if DEBUG
        signInWithE2EAccountIfNeeded()
        #endif
    }

    private func configureGoogleSignInIfPossible() {
        guard Self.hasConfiguredFirebaseApp else { return }
        guard let clientID = FirebaseApp.app()?.options.clientID else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    /// Firebase Auth on macOS uses `kSecUseDataProtectionKeychain`, which requires
    /// the SDK to be explicitly bound to the bundle's keychain access group when
    /// the Keychain Sharing entitlement is present. Without this call, persisting
    /// the signed-in user after Apple/Google sign-in fails with an opaque
    /// "keychain error" and the user is bounced back to the sign-in screen.
    /// See https://firebase.google.com/docs/ios/troubleshooting-faq.
    ///
    /// We discover the team-prefixed group at runtime (instead of hardcoding the
    /// 10-character Team ID) so the fix follows whatever signing identity Xcode
    /// selects, including the default app access group when Keychain Sharing is
    /// not explicitly configured. If the data-protection keychain is unavailable,
    /// the probe returns nil and we leave Firebase Auth on its default path.
    private func configureFirebaseAuthAccessGroup() {
        guard let group = Self.discoverKeychainAccessGroup() else { return }
        do {
            try bindFirebaseAuthAccessGroup(group)
        } catch {
            Self.logAuthFailure("Firebase Auth useUserAccessGroup", error)
            guard Self.isFirebaseAuthKeychainError(error),
                  Self.clearFirebaseAuthKeychainState(accessGroup: group) else {
                return
            }
            do {
                try bindFirebaseAuthAccessGroup(group)
                Self.authLogger.info("Firebase Auth access-group binding recovered after keychain cleanup.")
            } catch {
                Self.logAuthKeychainFailure(error)
            }
        }
    }

    private func bindFirebaseAuthAccessGroup(_ group: String) throws {
        try Auth.auth().useUserAccessGroup(group)
        firebaseAuthAccessGroup = group
    }

    /// Probes the keychain to discover the bundle's access group prefix
    /// (`<TeamID>.<bundle-id>`). Returns nil when no Keychain Sharing
    /// entitlement is present (writes fail with `errSecMissingEntitlement`).
    private static func discoverKeychainAccessGroup() -> String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "openburnbar.firebase-auth-access-group-probe",
            kSecAttrService as String: "openburnbar.firebase-auth-access-group-probe",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(probe as CFDictionary)
        var add = probe
        add[kSecValueData as String] = Data("probe".utf8)
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { return nil }
        defer { SecItemDelete(probe as CFDictionary) }

        var read = probe
        read[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        guard status == errSecSuccess,
              let attrs = item as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              group.contains(".") else {
            return nil
        }
        return group
    }

    private func observeAuthState() {
        guard authStateListenerHandle == nil else { return }
        authStateListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                self?.applyAuthStateSnapshot(user)
            }
        }
    }

    private func refreshAuthStateSnapshot() {
        guard isFirebaseAvailable, Self.hasConfiguredFirebaseApp else {
            applyAuthStateSnapshot(nil)
            return
        }
        applyAuthStateSnapshot(Auth.auth().currentUser)
    }

    private func applyAuthStateSnapshot(_ user: User?) {
        currentUser = user
        isSignedIn = user != nil
        isAnonymousUser = user?.isAnonymous ?? true
        userID = user?.uid
        userEmail = user?.email
        userDisplayName = user?.displayName ?? user?.email
    }

    #if DEBUG
    private func signInWithE2EAccountIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let token = environment["OPENBURNBAR_E2E_FIREBASE_CUSTOM_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = environment["OPENBURNBAR_E2E_FIREBASE_EMAIL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = environment["OPENBURNBAR_E2E_FIREBASE_PASSWORD"]
        guard token?.isEmpty == false || (email?.isEmpty == false && password?.isEmpty == false) else {
            return
        }

        let expectedUID = environment["OPENBURNBAR_E2E_FIREBASE_UID"]
        if let expectedUID, Auth.auth().currentUser?.uid == expectedUID {
            applyAuthStateSnapshot(Auth.auth().currentUser)
            Self.authLogger.info("OpenBurnBar E2E Firebase sign-in already active.")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let token, token.isEmpty == false {
                    let result = try await Auth.auth().signIn(withCustomToken: token)
                    self.applyAuthStateSnapshot(result.user)
                    Self.authLogger.info("OpenBurnBar E2E Firebase sign-in active uidSuffix=\(result.user.uid.suffix(6), privacy: .public).")
                } else if let email, let password {
                    let credential = EmailAuthProvider.credential(withEmail: email, password: password)
                    try await self.authenticate(with: credential)
                    guard let user = self.currentUser else {
                        throw AccountError.invalidCredential
                    }
                    Self.authLogger.info("OpenBurnBar E2E Firebase sign-in active uidSuffix=\(user.uid.suffix(6), privacy: .public).")
                } else {
                    return
                }
            } catch {
                Self.authLogger.error("OpenBurnBar E2E Firebase sign-in failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    #endif

    // MARK: - Sign In with Apple

    /// Call from `SignInWithAppleButton` request closure — returns SHA256(nonce) for the Apple request.
    func appleSignInNonceHash() -> String {
        let nonce = randomNonceString()
        currentNonce = nonce
        return sha256(nonce)
    }

    func signInWithAppleAuthorization(_ authorization: ASAuthorization) async throws {
        guard isFirebaseAvailable else {
            throw AccountError.firebaseNotConfigured
        }
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let appleIDToken = appleIDCredential.identityToken,
              let idTokenString = String(data: appleIDToken, encoding: .utf8),
              let rawNonce = currentNonce else {
            throw AccountError.invalidCredential
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: rawNonce,
            fullName: appleIDCredential.fullName
        )
        currentNonce = nil
        lastOAuthProviderID = "apple"
        lastOAuthToken = idTokenString
        lastOAuthEmail = appleIDCredential.email
        if let fullName = appleIDCredential.fullName {
            let formattedName = PersonNameComponentsFormatter().string(from: fullName)
            lastOAuthDisplayName = formattedName.isEmpty ? nil : formattedName
        } else {
            lastOAuthDisplayName = nil
        }
        try await authenticate(with: credential)
        if lastOAuthEmail == nil {
            lastOAuthEmail = currentUser?.email ?? userEmail
        }
        if lastOAuthDisplayName == nil {
            lastOAuthDisplayName = currentUser?.displayName ?? userDisplayName ?? lastOAuthEmail
        }
    }

    /// Presents Sign in with Apple from a window (Settings sheet, etc.).
    func signInWithApple(presentingWindow window: NSWindow) async throws {
        guard isFirebaseAvailable else {
            throw AccountError.firebaseNotConfigured
        }
        let nonceHash = appleSignInNonceHash()
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonceHash

        let controller = ASAuthorizationController(authorizationRequests: [request])

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = AppleSignInPresentationCoordinator(
                accountManager: self,
                window: window,
                controller: controller,
                continuation: continuation,
                onFinish: { [weak self] in
                    self?.appleSignInPresentation = nil
                }
            )
            appleSignInPresentation = coordinator
            coordinator.start()
        }
    }

    // MARK: - Sign In with Google

    func signInWithGoogle(presentingWindow window: NSWindow) async throws {
        guard isFirebaseAvailable else {
            throw AccountError.firebaseNotConfigured
        }
        guard Self.hasConfiguredFirebaseApp,
              let clientID = FirebaseApp.app()?.options.clientID else {
            throw AccountError.firebaseNotConfigured
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        let googleUser: GIDGoogleUser
        do {
            googleUser = try await googleSignInResult(presentingWindow: window).user
        } catch {
            Self.logAuthFailure("Google Sign-In", error)
            guard Self.isGoogleSignInKeychainError(error),
                  Self.clearGoogleSignInKeychainState(accessGroup: firebaseAuthAccessGroup) else {
                throw error
            }
            GIDSignIn.sharedInstance.signOut()
            do {
                googleUser = try await googleSignInResult(presentingWindow: window).user
            } catch {
                Self.logAuthFailure("Google Sign-In retry", error)
                throw error
            }
        }

        guard let idToken = googleUser.idToken?.tokenString else {
            throw AccountError.invalidCredential
        }
        let accessToken = googleUser.accessToken.tokenString
        lastOAuthProviderID = "google"
        lastOAuthToken = accessToken
        lastOAuthEmail = googleUser.profile?.email
        lastOAuthDisplayName = googleUser.profile?.name

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: accessToken
        )
        try await authenticate(with: credential)
        refreshAuthStateSnapshot()
        if lastOAuthEmail == nil {
            lastOAuthEmail = currentUser?.email ?? userEmail
        }
        if lastOAuthDisplayName == nil {
            lastOAuthDisplayName = currentUser?.displayName ?? userDisplayName ?? lastOAuthEmail
        }
    }

    func signInWithEmail(email: String, password: String) async throws {
        guard isFirebaseAvailable, Self.hasConfiguredFirebaseApp else {
            throw AccountError.firebaseNotConfigured
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        if let user = currentUser, user.isAnonymous {
            try await user.link(with: credential)
            refreshAuthStateSnapshot()
            return
        }
        try await Auth.auth().signIn(withEmail: email, password: password)
        refreshAuthStateSnapshot()
    }

    func signUpWithEmail(email: String, password: String) async throws {
        guard isFirebaseAvailable, Self.hasConfiguredFirebaseApp else {
            throw AccountError.firebaseNotConfigured
        }
        if let user = currentUser, user.isAnonymous {
            let credential = EmailAuthProvider.credential(withEmail: email, password: password)
            try await user.link(with: credential)
            refreshAuthStateSnapshot()
            return
        }
        try await Auth.auth().createUser(withEmail: email, password: password)
        refreshAuthStateSnapshot()
    }

    func deleteCurrentUser() async throws {
        guard isFirebaseAvailable, Self.hasConfiguredFirebaseApp,
              let user = Auth.auth().currentUser else {
            throw AccountError.firebaseNotConfigured
        }
        try await deleteCloudDataForCurrentUser()
        try await user.delete()
    }

    private func deleteCloudDataForCurrentUser() async throws {
        let callable = Functions.functions(region: "us-central1").httpsCallable("deleteUserCloudData")
        _ = try await callable.call([String: Any]())
    }

    // MARK: - Sign Out

    func signOut() throws {
        if isFirebaseAvailable {
            try Auth.auth().signOut()
        }
        GIDSignIn.sharedInstance.signOut()
        refreshAuthStateSnapshot()
        lastOAuthProviderID = nil
        lastOAuthToken = nil
        lastOAuthEmail = nil
        lastOAuthDisplayName = nil
    }

    // MARK: - Cloud Sync Toggle

    func setCloudSyncEnabled(_ enabled: Bool) {
        isCloudSyncEnabled = enabled
    }

    // MARK: - Device UUID

    private static func loadOrCreateDeviceId() -> String {
        OpenBurnBarMigration.migrateUserDefaults()
        let key = OpenBurnBarIdentity.deviceIDKey
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        for legacyKey in OpenBurnBarIdentity.legacyDeviceIDKeys {
            if let stored = UserDefaults.standard.string(forKey: legacyKey) {
                UserDefaults.standard.set(stored, forKey: key)
                return stored
            }
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    // MARK: - Nonce Helpers

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        precondition(errorCode == errSecSuccess, "SecRandomCopyBytes failed")
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func authenticate(with credential: AuthCredential) async throws {
        do {
            try await authenticateWithoutKeychainRecovery(with: credential)
        } catch {
            Self.logAuthFailure("Firebase Auth", error)
            guard Self.isFirebaseAuthKeychainError(error),
                  let group = firebaseAuthAccessGroup,
                  Self.clearFirebaseAuthKeychainState(accessGroup: group) else {
                throw error
            }
            do {
                try Auth.auth().useUserAccessGroup(group)
                try await authenticateWithoutKeychainRecovery(with: credential)
            } catch {
                Self.logAuthKeychainFailure(error)
                throw error
            }
        }
    }

    private func authenticateWithoutKeychainRecovery(with credential: AuthCredential) async throws {
        if let user = currentUser, user.isAnonymous {
            try await user.link(with: credential)
        } else {
            try await Auth.auth().signIn(with: credential)
        }
        refreshAuthStateSnapshot()
    }

    private func googleSignInResult(presentingWindow window: NSWindow) async throws -> GIDSignInResult {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GIDSignInResult, Error>) in
            Self.startGoogleSignIn(window: window) { signInResult, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let signInResult else {
                    continuation.resume(throwing: AccountError.invalidCredential)
                    return
                }
                continuation.resume(returning: signInResult)
            }
        }
    }

    private static func startGoogleSignIn(
        window: NSWindow,
        completion: @escaping @Sendable (GIDSignInResult?, Error?) -> Void
    ) {
        let presentationWindow = googleAuthPresentationWindow(from: window)
        authLogger.info("Starting Google Sign-In with ASWebAuthenticationSession")
        GIDSignIn.sharedInstance.signIn(withPresenting: presentationWindow) { result, error in
            completion(result, error)
        }
    }

    private static func googleAuthPresentationWindow(from window: NSWindow) -> NSWindow {
        var candidate = window
        while let parent = candidate.sheetParent {
            candidate = parent
        }
        if candidate.isVisible, !candidate.isMiniaturized {
            NSApp.activate(ignoringOtherApps: true)
            candidate.makeKeyAndOrderFront(nil)
            return candidate
        }
        let fallback = NSApp.windows.first { $0.isVisible && !$0.isMiniaturized && $0.sheetParent == nil }
        if let fallback {
            NSApp.activate(ignoringOtherApps: true)
            fallback.makeKeyAndOrderFront(nil)
            return fallback
        }
        return window
    }

    private static func isGoogleSignInKeychainError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "com.google.GIDSignIn" && nsError.code == -2 {
            return true
        }

        let fields = errorSearchFields(nsError)
        let mentionsKeychain = fields.contains {
            $0.localizedCaseInsensitiveContains("keychain")
        }
        guard mentionsKeychain else { return false }

        // This classifier only runs inside the Google Sign-In flow. Broaden the
        // dependency-domain check so SDK wrapper changes do not bypass recovery.
        return fields.contains { field in
            field.localizedCaseInsensitiveContains("google")
                || field.localizedCaseInsensitiveContains("gidsignin")
                || field.localizedCaseInsensitiveContains("gtmappauth")
                || field.localizedCaseInsensitiveContains("appauth")
        }
    }

    private static func clearGoogleSignInKeychainState(accessGroup: String?) -> Bool {
        var statuses = [
            ("default", deleteGoogleSignInAuthState(accessGroup: nil, useDataProtectionKeychain: false), false),
            ("default-dp", deleteGoogleSignInAuthState(accessGroup: nil, useDataProtectionKeychain: true), true)
        ]
        if let accessGroup {
            statuses.append(contentsOf: [
                (
                    "access-group",
                    deleteGoogleSignInAuthState(accessGroup: accessGroup, useDataProtectionKeychain: false),
                    false
                ),
                (
                    "access-group-dp",
                    deleteGoogleSignInAuthState(accessGroup: accessGroup, useDataProtectionKeychain: true),
                    true
                )
            ])
        }

        for (label, status, _) in statuses {
            authLogger.info("Google Sign-In keychain cleanup \(label, privacy: .public) status=\(status)")
        }

        return statuses.allSatisfy { _, status, isDataProtectionQuery in
            isRecoverableKeychainDeleteStatus(status, allowMissingEntitlement: isDataProtectionQuery)
        }
    }

    private static func deleteGoogleSignInAuthState(
        accessGroup: String?,
        useDataProtectionKeychain: Bool
    ) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "auth",
            kSecAttrAccount as String: "OAuth"
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return SecItemDelete(query as CFDictionary)
    }

    private static func isFirebaseAuthKeychainError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let fields = errorSearchFields(nsError)
        return fields.contains { $0.localizedCaseInsensitiveContains("keychain") }
    }

    private static func clearFirebaseAuthKeychainState(accessGroup: String) -> Bool {
        guard let firebase = firebaseAuthKeychainIdentifiers() else { return false }
        let accessGroupStatuses = [
            deleteAuthStoredUser(accessGroup: accessGroup, service: firebase.apiKey, synchronizable: false),
            deleteAuthStoredUser(accessGroup: accessGroup, service: firebase.apiKey, synchronizable: true)
        ]
        let defaultStatuses = [
            deleteDefaultAuthUser(service: firebase.serviceName, appName: firebase.appName),
            deleteLegacyDefaultAuthUser(appName: firebase.appName),
            deleteServiceScopedLegacyAuthUser(service: firebase.serviceName, appName: firebase.appName)
        ]

        for (index, status) in (accessGroupStatuses + defaultStatuses).enumerated() {
            authLogger.info("Firebase Auth keychain cleanup index=\(index) status=\(status)")
        }

        return accessGroupStatuses.allSatisfy(isRecoverableFirebaseAuthKeychainDeleteStatus)
            && defaultStatuses.allSatisfy(isRecoverableDefaultFirebaseAuthKeychainDeleteStatus)
    }

    private static func deleteAuthStoredUser(accessGroup: String, service: String, synchronizable: Bool) -> OSStatus {
        SecItemDelete(firebaseAuthStoredUserDeleteQuery(
            accessGroup: accessGroup,
            service: service,
            synchronizable: synchronizable
        ) as CFDictionary)
    }

    private static func firebaseAuthStoredUserDeleteQuery(
        accessGroup: String,
        service: String,
        synchronizable: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "firebase_auth_firebase_user",
            kSecUseDataProtectionKeychain as String: true
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    private static func deleteDefaultAuthUser(service: String, appName: String) -> OSStatus {
        SecItemDelete(firebaseAuthDefaultStoredUserDeleteQuery(
            service: service,
            appName: appName
        ) as CFDictionary)
    }

    private static func firebaseAuthDefaultStoredUserDeleteQuery(
        service: String,
        appName: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "firebase_auth_1_\(appName)_firebase_user",
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func deleteLegacyDefaultAuthUser(appName: String) -> OSStatus {
        SecItemDelete(firebaseAuthLegacyDefaultStoredUserDeleteQuery(
            appName: appName
        ) as CFDictionary)
    }

    private static func firebaseAuthLegacyDefaultStoredUserDeleteQuery(appName: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "\(appName)_firebase_user"
        ]
    }

    private static func deleteServiceScopedLegacyAuthUser(service: String, appName: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(appName)_firebase_user",
            kSecUseDataProtectionKeychain as String: true
        ]
        return SecItemDelete(query as CFDictionary)
    }

    private static func isRecoverableFirebaseAuthKeychainDeleteStatus(_ status: OSStatus) -> Bool {
        isRecoverableKeychainDeleteStatus(status, allowMissingEntitlement: false)
    }

    private static func isRecoverableDefaultFirebaseAuthKeychainDeleteStatus(_ status: OSStatus) -> Bool {
        isRecoverableKeychainDeleteStatus(status, allowMissingEntitlement: true)
    }

    private static func isRecoverableKeychainDeleteStatus(
        _ status: OSStatus,
        allowMissingEntitlement: Bool
    ) -> Bool {
        status == errSecSuccess
            || status == errSecItemNotFound
            || (allowMissingEntitlement && status == errSecMissingEntitlement)
    }

    private static func firebaseAuthKeychainIdentifiers() -> (
        apiKey: String,
        googleAppID: String,
        serviceName: String,
        appName: String
    )? {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = plist as? [String: Any],
              let apiKey = values["API_KEY"] as? String,
              let googleAppID = values["GOOGLE_APP_ID"] as? String else {
            return nil
        }
        return (
            apiKey: apiKey,
            googleAppID: googleAppID,
            serviceName: "firebase_auth_\(googleAppID)",
            appName: FirebaseApp.app()?.name ?? "__FIRAPP_DEFAULT"
        )
    }

    private static func logAuthKeychainFailure(_ error: Error) {
        logAuthFailure("Firebase Auth keychain recovery", error)
    }

    private static func logAuthFailure(_ label: String, _ error: Error) {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let underlyingSummary = underlying.map { "\($0.domain)#\($0.code)" } ?? "none"
        authLogger.error(
            "\(label, privacy: .public) failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code) description=\(nsError.localizedDescription, privacy: .public) failureReason=\(nsError.localizedFailureReason ?? "none", privacy: .public) underlying=\(underlyingSummary, privacy: .public)"
        )
    }

    private static func errorSearchFields(_ nsError: NSError) -> [String] {
        var fields = [
            nsError.domain,
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion
        ].compactMap(\.self)

        for (key, value) in nsError.userInfo {
            fields.append(String(describing: key))
            if let nested = value as? NSError {
                fields.append(contentsOf: errorSearchFields(nested))
            } else {
                fields.append(String(describing: value))
            }
        }
        return fields
    }

    #if DEBUG
    static func isGoogleSignInKeychainErrorForTesting(_ error: Error) -> Bool {
        isGoogleSignInKeychainError(error)
    }

    static func isFirebaseAuthKeychainErrorForTesting(_ error: Error) -> Bool {
        isFirebaseAuthKeychainError(error)
    }

    static func isRecoverableFirebaseAuthKeychainDeleteStatusForTesting(_ status: OSStatus) -> Bool {
        isRecoverableFirebaseAuthKeychainDeleteStatus(status)
    }

    static func isRecoverableDefaultFirebaseAuthKeychainDeleteStatusForTesting(_ status: OSStatus) -> Bool {
        isRecoverableDefaultFirebaseAuthKeychainDeleteStatus(status)
    }

    static func firebaseAuthStoredUserDeleteQueryForTesting(
        accessGroup: String,
        service: String,
        synchronizable: Bool
    ) -> [String: Any] {
        firebaseAuthStoredUserDeleteQuery(
            accessGroup: accessGroup,
            service: service,
            synchronizable: synchronizable
        )
    }

    static func firebaseAuthDefaultStoredUserDeleteQueryForTesting(
        service: String,
        appName: String
    ) -> [String: Any] {
        firebaseAuthDefaultStoredUserDeleteQuery(service: service, appName: appName)
    }

    static func firebaseAuthLegacyDefaultStoredUserDeleteQueryForTesting(
        appName: String
    ) -> [String: Any] {
        firebaseAuthLegacyDefaultStoredUserDeleteQuery(appName: appName)
    }

    static func googleAuthPresentationWindowForTesting(from window: NSWindow) -> NSWindow {
        googleAuthPresentationWindow(from: window)
    }
    #endif
}

// MARK: - AccountError

enum AccountError: LocalizedError {
    case firebaseNotConfigured
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .firebaseNotConfigured:
            return "Firebase is not configured. Add GoogleService-Info.plist to the app bundle."
        case .invalidCredential:
            return "Sign in failed: invalid credential received from the provider."
        }
    }
}

// MARK: - Sign in with Apple (presentation)

private final class AppleSignInPresentationCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let accountManager: AccountManager
    private weak var window: NSWindow?
    private let controller: ASAuthorizationController
    private var continuation: CheckedContinuation<Void, Error>?
    private let onFinish: () -> Void

    init(
        accountManager: AccountManager,
        window: NSWindow,
        controller: ASAuthorizationController,
        continuation: CheckedContinuation<Void, Error>,
        onFinish: @escaping () -> Void
    ) {
        self.accountManager = accountManager
        self.window = window
        self.controller = controller
        self.continuation = continuation
        self.onFinish = onFinish
        super.init()
        controller.delegate = self
        controller.presentationContextProvider = self
    }

    func start() {
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        window ?? NSApp.keyWindow ?? NSWindow()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let cont = continuation
        continuation = nil
        Task {
            do {
                try await accountManager.signInWithAppleAuthorization(authorization)
                cont?.resume()
                onFinish()
            } catch {
                cont?.resume(throwing: error)
                onFinish()
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let cont = continuation
        continuation = nil
        cont?.resume(throwing: error)
        onFinish()
    }
}
