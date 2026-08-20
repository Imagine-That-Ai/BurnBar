package com.openburnbar.data.media

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class ContentBlake3Test {
    @Test
    fun officialEmptyAndAbcVectors() {
        assertEquals(
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
            ContentBlake3.hash(ByteArray(0)),
        )
        assertEquals(
            "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85",
            ContentBlake3.hash("abc".toByteArray()),
        )
    }

    @Test
    fun ticketsAreNotHashes() {
        val file = File.createTempFile("blake3", ".bin")
        file.writeText("abc")
        val digest = ContentBlake3.hashFile(file)
        assertEquals(ContentBlake3.hash("abc".toByteArray()), digest)
        val hashed = ContentBlake3.parseOrHash("blob1faketicket", file)
        assertEquals(digest, hashed)
    }
}
