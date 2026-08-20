package com.openburnbar.data.media

import com.openburnbar.test.requireClassLoaderResourceText
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class FileSealAEADVectorTest {
    private val fixture: JSONObject by lazy {
        JSONObject(requireClassLoaderResourceText(javaClass.classLoader, "media-aead/FileSealAEADVector.json"))
    }

    @Test
    fun positiveVectorsRoundTrip() {
        val headerJson = fixture.getJSONObject("header")
        val header = FileSealAEAD.Header(
            attachmentId = headerJson.getString("attachmentId"),
            totalChunks = headerJson.getInt("totalChunks"),
            plaintextSize = headerJson.getLong("plaintextSize"),
            contentBlake3 = headerJson.getString("contentBlake3"),
        )
        val key = hex(fixture.getString("contentKeyHex"))
        val cases = fixture.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val item = cases.getJSONObject(i)
            val nonce = hex(item.getString("nonceHex"))
            val plaintext = item.getString("plaintextUtf8").toByteArray(Charsets.UTF_8)
            val sealed = FileSealAEAD.sealChunk(
                plaintext,
                key,
                header,
                item.getLong("chunkIndex"),
                nonce,
            )
            assertEquals(item.getString("name"), item.getString("ciphertextHex"), sealed.first.toHex())
            assertEquals(item.getString("name"), item.getString("tagHex"), sealed.second.toHex())
            val opened = FileSealAEAD.openChunk(
                sealed.first,
                sealed.second,
                key,
                header,
                item.getLong("chunkIndex"),
                nonce,
            )
            assertArrayEquals(plaintext, opened)
        }
    }

    @Test
    fun flippedIndexFailsAuthentication() {
        val headerJson = fixture.getJSONObject("header")
        val header = FileSealAEAD.Header(
            attachmentId = headerJson.getString("attachmentId"),
            totalChunks = headerJson.getInt("totalChunks"),
            plaintextSize = headerJson.getLong("plaintextSize"),
            contentBlake3 = headerJson.getString("contentBlake3"),
        )
        val item = fixture.getJSONArray("cases").getJSONObject(0)
        assertThrows(Exception::class.java) {
            FileSealAEAD.openChunk(
                hex(item.getString("ciphertextHex")),
                hex(item.getString("tagHex")),
                hex(fixture.getString("contentKeyHex")),
                header,
                1,
                hex(item.getString("nonceHex")),
            )
        }
    }

    private fun hex(value: String): ByteArray {
        val clean = value.replace(" ", "")
        return ByteArray(clean.length / 2) { i ->
            clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
