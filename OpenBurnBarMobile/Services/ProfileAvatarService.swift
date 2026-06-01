import Foundation
import FirebaseAuth
import FirebaseStorage
import UIKit
import OSLog

// MARK: - Profile Avatar Service
//
// Uploads a UIImage to Firebase Storage at
//   avatars/{uid}/profile.jpg
// then calls Auth.currentUser.updateProfile to point photoURL at the
// new download URL. Returns the new URL so callers can optimistically
// update their UI.

@MainActor
final class ProfileAvatarService {
    private static let logger = Logger(subsystem: "com.openburnbar.app", category: "ProfileAvatarService")

    enum AvatarError: LocalizedError {
        case notSignedIn
        case compressionFailed
        case uploadFailed(Error)
        case downloadURLFailed(Error)
        case profileUpdateFailed(Error)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:             return "You must be signed in to change your photo."
            case .compressionFailed:       return "Could not compress the selected image."
            case .uploadFailed(let e):     return "Upload failed: \(e.localizedDescription)"
            case .downloadURLFailed(let e): return "Could not get download URL: \(e.localizedDescription)"
            case .profileUpdateFailed(let e): return "Could not update profile: \(e.localizedDescription)"
            }
        }
    }

    /// Upload `image` and update the authenticated user's Firebase Auth photoURL.
    /// Returns the new remote URL on success.
    func upload(_ image: UIImage) async throws -> URL {
        guard let user = Auth.auth().currentUser else { throw AvatarError.notSignedIn }

        // Compress to JPEG — 256 KB target is plenty for a small avatar
        guard let data = image.jpegData(compressionQuality: 0.75) else { throw AvatarError.compressionFailed }

        let path = "avatars/\(user.uid)/profile.jpg"
        let ref = Storage.storage().reference().child(path)
        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"

        Self.logger.debug("Uploading avatar to \(path)")
        do {
            _ = try await ref.putDataAsync(data, metadata: meta)
        } catch {
            throw AvatarError.uploadFailed(error)
        }

        let downloadURL: URL
        do {
            downloadURL = try await ref.downloadURL()
        } catch {
            throw AvatarError.downloadURLFailed(error)
        }

        let changeRequest = user.createProfileChangeRequest()
        changeRequest.photoURL = downloadURL
        do {
            try await changeRequest.commitChanges()
        } catch {
            throw AvatarError.profileUpdateFailed(error)
        }

        Self.logger.info("Avatar updated")
        return downloadURL
    }
}
