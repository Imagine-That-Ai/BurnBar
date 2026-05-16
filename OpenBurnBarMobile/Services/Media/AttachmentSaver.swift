import Foundation

#if canImport(UIKit)
import UIKit
#endif
#if canImport(Photos)
import Photos
#endif

import OpenBurnBarCore

/// iOS-side save router for inbound Mercury attachments. Implements
/// Decision 3 (`plans/2026-05-15-mercury-media-master-plan.md`):
///
/// 1. First image attachment from a given paired Mac: present action
///    sheet ("Save to Photos" / "Save to Files"); persist the choice.
/// 2. Subsequent images from the same partner: route automatically per
///    the persisted preference.
/// 3. Non-image MIME types: always route through
///    `UIDocumentPickerViewController` because Photos rejects them
///    anyway.
///
/// The platform UI (action sheet, picker presentation) lives in
/// `AttachmentBubble` — this class is the headless router.
@MainActor
final class AttachmentSaver {
    enum Failure: Error, LocalizedError {
        case photosPermissionDenied
        case photosUnavailable
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .photosPermissionDenied:
                return "Photos access is denied. Open Settings → OpenBurnBar to allow saving."
            case .photosUnavailable:
                return "Photos library is unavailable on this device."
            case .writeFailed(let message):
                return message
            }
        }
    }

    private let preferences: MediaPartnerSavePreferenceStore

    init(preferences: MediaPartnerSavePreferenceStore = .shared) {
        self.preferences = preferences
    }

    /// Whether the inbound MIME type is a supported image kind that can
    /// be routed to Photos. Anything outside this list always falls
    /// through to Files via `UIDocumentPickerViewController`.
    static func isPhotoCandidate(mime: String) -> Bool {
        switch mime.lowercased() {
        case "image/png", "image/jpeg", "image/jpg", "image/heic", "image/gif":
            return true
        default:
            return false
        }
    }

    /// Looks up the per-partner preference, defaulting to `.askEachTime`.
    func resolvedPreference(forPeerDeviceId peerDeviceId: String) async -> MediaPartnerSavePreferenceStore.SavePreference {
        await preferences.preference(forPeerDeviceId: peerDeviceId)
    }

    /// Persist the choice the user made on the action sheet so the next
    /// image from the same Mac is routed automatically.
    func rememberChoice(
        _ preference: MediaPartnerSavePreferenceStore.SavePreference,
        forPeerDeviceId peerDeviceId: String
    ) async {
        await preferences.setPreference(preference, forPeerDeviceId: peerDeviceId)
    }

    /// Save an image asset into the Photos library. Throws if the user
    /// declined Photos permission. Callers should fall through to Files
    /// on failure.
    func saveToPhotos(fileURL: URL) async throws {
        #if canImport(Photos) && canImport(UIKit)
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let granted: Bool
        switch status {
        case .authorized, .limited:
            granted = true
        case .denied, .restricted:
            granted = false
        case .notDetermined:
            granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        @unknown default:
            granted = false
        }
        guard granted else { throw Failure.photosPermissionDenied }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: fileURL, options: nil)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Failure.writeFailed(error?.localizedDescription ?? "Photos write failed."))
                }
            }
        }
        #else
        throw Failure.photosUnavailable
        #endif
    }
}
