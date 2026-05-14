package com.openburnbar

import com.openburnbar.data.hermes.HermesSessionParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HermesSessionParserTest {

    @Test
    fun `parses sessions wrapped in sessions key`() {
        val body = """
        {
          "sessions": [
            {
              "id": "abc",
              "title": "First session",
              "preview": "hello",
              "model": "hermes-1.7",
              "started_at": 1700000000,
              "last_active_at": 1700000100,
              "message_count": 3
            }
          ]
        }
        """.trimIndent()
        val out = HermesSessionParser.parseSessions(body)
        assertEquals(1, out.size)
        assertEquals("abc", out.first().id)
        assertEquals("First session", out.first().title)
        assertEquals(3, out.first().messageCount)
        assertEquals(1_700_000_000_000L, out.first().startedAt)
    }

    @Test
    fun `parses sessions as a bare array body`() {
        val body = "[{\"id\":\"only\",\"title\":\"Only\"}]"
        val out = HermesSessionParser.parseSessions(body)
        assertEquals(1, out.size)
        assertEquals("only", out.first().id)
    }

    @Test
    fun `parses session detail with content as a string`() {
        val body = """
        {
          "messages": [
            {"role": "user", "content": "ping"},
            {"role": "assistant", "content": "pong"}
          ]
        }
        """.trimIndent()
        val out = HermesSessionParser.parseSessionMessages(body)
        assertEquals(2, out.size)
        assertEquals("user", out[0].role)
        assertEquals("ping", out[0].text)
        assertEquals("assistant", out[1].role)
        assertEquals("pong", out[1].text)
    }

    @Test
    fun `parses session detail with content as a parts array`() {
        val body = """
        {
          "messages": [
            {"role": "user", "content": [{"type":"text","text":"part1"},{"type":"text","text":"part2"}]}
          ]
        }
        """.trimIndent()
        val out = HermesSessionParser.parseSessionMessages(body)
        assertEquals(1, out.size)
        assertTrue(out[0].text.contains("part1"))
        assertTrue(out[0].text.contains("part2"))
    }

    @Test
    fun `tolerates empty body`() {
        assertEquals(0, HermesSessionParser.parseSessions("").size)
        assertEquals(0, HermesSessionParser.parseSessionMessages("").size)
    }
}
