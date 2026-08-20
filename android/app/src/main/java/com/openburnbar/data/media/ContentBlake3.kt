package com.openburnbar.data.media

import java.io.File

/** Content-addressed blake3 helpers. Ticket strings are not hashes. */
object ContentBlake3 {
    fun parse(raw: String): String {
        var value = raw.trim().lowercase()
        if (value.startsWith("blake3:")) value = value.removePrefix("blake3:")
        require(value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }) {
            "blobHash must be a 64-hex blake3 digest, not a ticket"
        }
        return value
    }

    fun parseOrHash(ticketOrHash: String, file: File): String {
        return runCatching { parse(ticketOrHash) }.getOrElse {
            // Local publish must not stuff the iroh ticket into blobHash.
            parse(hashFilePlaceholder(file))
        }
    }

    private fun hashFilePlaceholder(file: File): String {
        require(file.isFile) { "missing file for content hash" }
        // Prefer an already-hex name; otherwise fail closed rather than using the ticket.
        throw IllegalArgumentException("blobHash must be a blake3 content hash, not a ticket string")
    }
}
