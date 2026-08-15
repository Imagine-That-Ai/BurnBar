@preconcurrency import Foundation
import Combine
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore

/// Live Memory Boost wallet cache. Cloud Functions are the sole writer;
/// this listener only reads `users/{uid}/memoryWallet/current`.
@MainActor
final class MacMemoryWalletStore: ObservableObject {
    @Published private(set) var textTokens: Int = 0
    @Published private(set) var multimodalTokens: Int = 0
    @Published private(set) var pendingTextTokens: Int = 0
    @Published private(set) var pendingMultimodalTokens: Int = 0
    @Published private(set) var loadFailed: Bool = false

    private var listener: ListenerRegistration?
    private nonisolated(unsafe) var authHandle: AuthStateDidChangeListenerHandle?
    private var started = false

    func start() {
        guard !started else { return }
        guard FirebaseApp.app() != nil else { return }
        started = true
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.listen(uid: user?.uid)
            }
        }
        listen(uid: Auth.auth().currentUser?.uid)
    }

    func stop() {
        listener?.remove()
        listener = nil
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
            self.authHandle = nil
        }
        started = false
        resetBalances()
        loadFailed = false
    }

    private func listen(uid: String?) {
        listener?.remove()
        listener = nil
        guard let uid, FirebaseApp.app() != nil else {
            resetBalances()
            loadFailed = false
            return
        }
        listener = Firestore.firestore()
            .document("users/\(uid)/memoryWallet/current")
            .addSnapshotListener { [weak self] snap, error in
                let data = snap?.data()
                let failed = error != nil
                Task { @MainActor in
                    guard let self else { return }
                    if failed {
                        self.loadFailed = true
                        return
                    }
                    self.loadFailed = false
                    self.textTokens = Self.intValue(data?["textTokens"])
                    self.multimodalTokens = Self.intValue(data?["multimodalTokens"])
                    self.pendingTextTokens = Self.intValue(data?["pendingTextTokens"])
                    self.pendingMultimodalTokens = Self.intValue(data?["pendingMultimodalTokens"])
                }
            }
    }

    private func resetBalances() {
        textTokens = 0
        multimodalTokens = 0
        pendingTextTokens = 0
        pendingMultimodalTokens = 0
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 { return Int(value) }
        if let value = raw as? Double { return Int(value) }
        return 0
    }
}
