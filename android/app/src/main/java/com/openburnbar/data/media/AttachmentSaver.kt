package com.openburnbar.data.media

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.io.IOException

/**
 * Android-side save router for inbound Mercury attachments. 1:1 port of
 * `AttachmentSaver.swift` (iOS):
 *
 * 1. First image attachment from a given paired Mac: present action
 *    sheet ("Save to Photos" / "Save to Files"); persist the choice.
 * 2. Subsequent images from the same partner: route automatically per
 *    the persisted preference.
 * 3. Non-image MIME types: always route through SAF
 *    (`ACTION_CREATE_DOCUMENT`).
 *
 * Image route → `MediaStore.Images.Media` (scoped storage). Files route
 * → SAF picker URI passed in from the UI activity result; the result
 * URI is `ContentResolver`-writable.
 *
 * The UI affordance (action sheet, picker presentation) lives in
 * `AttachmentBubble` Compose — this class is the headless router.
 */
class AttachmentSaver(
    private val context: Context,
    private val preferences: MediaPartnerSavePreferenceStore,
) {
    sealed class SaveResult {
        data class Succeeded(val uri: Uri) : SaveResult()
        data class Failed(val message: String) : SaveResult()
    }

    suspend fun resolvedPreference(
        peerDeviceId: String,
    ): MediaPartnerSavePreferenceStore.SavePreference =
        preferences.preference(peerDeviceId)

    suspend fun rememberChoice(
        preference: MediaPartnerSavePreferenceStore.SavePreference,
        peerDeviceId: String,
    ) {
        preferences.setPreference(preference, peerDeviceId)
    }

    /**
     * Save an image asset into `MediaStore.Images.Media` (Photos
     * equivalent). On API 28 and below, falls back to scoped Downloads.
     */
    suspend fun saveToPhotos(
        sourceFile: File,
        displayName: String,
        mime: String,
    ): SaveResult = withContext(Dispatchers.IO) {
        try {
            val resolver = context.contentResolver
            val collection: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Images.Media.MIME_TYPE, mime)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/OpenBurnBar")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
            }
            val uri = resolver.insert(collection, values) ?: return@withContext SaveResult.Failed(
                "MediaStore insert returned null"
            )
            resolver.openOutputStream(uri).use { out ->
                if (out == null) return@withContext SaveResult.Failed("Output stream unavailable")
                FileInputStream(sourceFile).use { input -> input.copyTo(out) }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
                    null,
                    null,
                )
            }
            SaveResult.Succeeded(uri)
        } catch (e: IOException) {
            SaveResult.Failed(e.message ?: "I/O failure writing to Photos")
        }
    }

    /**
     * Save an arbitrary attachment via a destination URI obtained from
     * `ACTION_CREATE_DOCUMENT` (handed in by the caller activity).
     */
    suspend fun saveToFiles(
        sourceFile: File,
        destinationUri: Uri,
    ): SaveResult = withContext(Dispatchers.IO) {
        try {
            val resolver = context.contentResolver
            resolver.openOutputStream(destinationUri).use { out ->
                if (out == null) return@withContext SaveResult.Failed("Output stream unavailable")
                FileInputStream(sourceFile).use { input -> input.copyTo(out) }
            }
            SaveResult.Succeeded(destinationUri)
        } catch (e: IOException) {
            SaveResult.Failed(e.message ?: "I/O failure writing to Files")
        }
    }

    /**
     * Save into a previously-granted tree URI (persisted partner-level
     * Files preference). Creates a new document inside the tree.
     */
    suspend fun saveToTree(
        sourceFile: File,
        treeUri: Uri,
        displayName: String,
        mime: String,
    ): SaveResult = withContext(Dispatchers.IO) {
        try {
            val tree = DocumentFile.fromTreeUri(context, treeUri)
                ?: return@withContext SaveResult.Failed("Cannot resolve tree URI")
            val document = tree.createFile(mime, displayName)
                ?: return@withContext SaveResult.Failed("Cannot create file inside tree")
            context.contentResolver.openOutputStream(document.uri).use { out ->
                if (out == null) return@withContext SaveResult.Failed("Output stream unavailable")
                FileInputStream(sourceFile).use { input -> input.copyTo(out) }
            }
            SaveResult.Succeeded(document.uri)
        } catch (e: IOException) {
            SaveResult.Failed(e.message ?: "I/O failure writing to tree URI")
        }
    }

    companion object {
        /**
         * Whether the inbound MIME type is a supported image kind that
         * can be routed to `MediaStore.Images.Media`. Anything outside
         * this list falls through to SAF.
         */
        fun isPhotoCandidate(mime: String): Boolean = when (mime.lowercase()) {
            "image/png", "image/jpeg", "image/jpg", "image/heic", "image/heif", "image/gif", "image/webp" -> true
            else -> false
        }

        @Suppress("unused")
        fun externalPicturesRoot(): File = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_PICTURES
        )
    }
}
