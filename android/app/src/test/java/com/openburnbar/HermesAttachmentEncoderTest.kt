package com.openburnbar

import com.openburnbar.data.hermes.HermesAttachment
import com.openburnbar.data.hermes.HermesAttachmentEncoder
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Verifies the multimodal payload shape that hits `/v1/chat/completions`. */
class HermesAttachmentEncoderTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun `empty attachments returns plain string`() {
        val encoded = HermesAttachmentEncoder.encodeUserTurn("hello", emptyList())
        assertEquals("hello", encoded)
    }

    @Test
    fun `with attachments returns array of text and image parts`() {
        val attachments = listOf(
            HermesAttachment(fileName = "note.txt", mimeType = "text/plain"),
            HermesAttachment(fileName = "snap.jpg", mimeType = "image/jpeg")
        )
        val encoded = HermesAttachmentEncoder.encodeUserTurn("describe", attachments) as JSONArray
        assertEquals(3, encoded.length())
        assertEquals("text", encoded.getJSONObject(0).getString("type"))
        // Both attachments lack absolutePath in this unit test, so the
        // encoder falls back to a text part announcing them.
        assertTrue(encoded.getJSONObject(1).has("type"))
        assertTrue(encoded.getJSONObject(2).has("type"))
    }

    @Test
    fun `blank prompt with attachment skips the leading text part`() {
        val attachments = listOf(
            HermesAttachment(fileName = "snap.jpg", mimeType = "image/jpeg")
        )
        val encoded = HermesAttachmentEncoder.encodeUserTurn("", attachments) as JSONArray
        assertEquals(1, encoded.length())
    }

    @Test
    fun `materialised image becomes a base64 image_url data part`() {
        // Two-byte PNG header is enough to prove the encoder uses the file body.
        val pngBytes = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        val image = tempFolder.newFile("hermes-fixture.png")
        image.writeBytes(pngBytes)

        val attachment = HermesAttachment(
            fileName = "hermes-fixture.png",
            mimeType = "image/png",
            absolutePath = image.absolutePath,
            sizeBytes = pngBytes.size.toLong()
        )
        val encoded = HermesAttachmentEncoder.encodeUserTurn("describe this image", listOf(attachment)) as JSONArray
        assertEquals(2, encoded.length())
        val imagePart = encoded.getJSONObject(1)
        assertEquals("image_url", imagePart.getString("type"))
        val url = imagePart.getJSONObject("image_url").getString("url")
        assertTrue("Image URL must be inline base64", url.startsWith("data:image/png;base64,"))
        // 8 bytes → "iVBORw0KGgo=" prefix (Base64 of PNG signature, no wrap)
        assertTrue("Image URL must contain the PNG body bytes", url.endsWith("iVBORw0KGgo="))
    }

    @Test
    fun `materialised text becomes an inline text part with the file body`() {
        val txt = tempFolder.newFile("notes.txt")
        txt.writeText("hello hermes")
        val attachment = HermesAttachment(
            fileName = "notes.txt",
            mimeType = "text/plain",
            absolutePath = txt.absolutePath,
            sizeBytes = txt.length()
        )
        val encoded = HermesAttachmentEncoder.encodeUserTurn("read this", listOf(attachment)) as JSONArray
        val textPart = encoded.getJSONObject(1)
        assertEquals("text", textPart.getString("type"))
        assertTrue(textPart.getString("text").contains("hello hermes"))
    }
}
