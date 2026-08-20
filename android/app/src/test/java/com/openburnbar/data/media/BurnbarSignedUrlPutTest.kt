package com.openburnbar.data.media

import com.sun.net.httpserver.HttpServer
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnbarSignedUrlPutTest {
    private data class ReceivedPut(
        val method: String,
        val generationGuard: String?,
        val contentType: String?,
        val body: String,
    )

    @Test
    fun putsFileWithCreateOnlyGuardAndReturnsResponseCode() {
        val received = AtomicReference<ReceivedPut>()
        val server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/part") { exchange ->
            received.set(
                ReceivedPut(
                    method = exchange.requestMethod,
                    generationGuard = exchange.requestHeaders.getFirst("x-goog-if-generation-match"),
                    contentType = exchange.requestHeaders.getFirst("Content-Type"),
                    body = exchange.requestBody.readBytes().decodeToString(),
                ),
            )
            exchange.sendResponseHeaders(200, -1)
            exchange.close()
        }
        server.start()
        try {
            val file = File.createTempFile("burnbar-put", ".bin").apply {
                deleteOnExit()
                writeText("sealed-part-bytes")
            }
            val code = BurnbarSignedUrlPut.put(file, "http://127.0.0.1:${server.address.port}/part")

            assertEquals(200, code)
            val put = received.get()
            assertEquals("PUT", put.method)
            assertEquals("0", put.generationGuard)
            assertEquals("application/octet-stream", put.contentType)
            assertEquals("sealed-part-bytes", put.body)
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun surfacesNonSuccessResponseCodes() {
        val server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/part") { exchange ->
            exchange.requestBody.readBytes()
            exchange.sendResponseHeaders(412, -1)
            exchange.close()
        }
        server.start()
        try {
            val file = File.createTempFile("burnbar-put", ".bin").apply {
                deleteOnExit()
                writeText("x")
            }
            val code = BurnbarSignedUrlPut.put(file, "http://127.0.0.1:${server.address.port}/part")
            assertEquals(412, code)
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun successRangeCoversExactlyThe2xxFamily() {
        assertTrue(BurnbarSignedUrlPut.isSuccess(200))
        assertTrue(BurnbarSignedUrlPut.isSuccess(204))
        assertTrue(BurnbarSignedUrlPut.isSuccess(299))
        assertFalse(BurnbarSignedUrlPut.isSuccess(199))
        assertFalse(BurnbarSignedUrlPut.isSuccess(301))
        assertFalse(BurnbarSignedUrlPut.isSuccess(412))
        assertFalse(BurnbarSignedUrlPut.isSuccess(500))
    }
}
