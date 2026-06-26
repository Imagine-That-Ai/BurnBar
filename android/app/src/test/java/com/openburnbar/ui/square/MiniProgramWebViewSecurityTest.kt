package com.openburnbar.ui.square

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MiniProgramWebViewSecurityTest {
    @Test
    fun sandboxOriginUsesParsedAuthorityInsteadOfStringPrefix() {
        val origin = MiniProgramSandboxOrigin.parse("https://agents.example.com/card/index.html")

        assertNotNull(origin)
        assertEquals("https://agents.example.com", origin?.origin)
        assertTrue(isAllowedMiniProgramNavigation("https://agents.example.com/card/next", origin))
        assertFalse(isAllowedMiniProgramNavigation("https://agents.example.com.evil/card/next", origin))
        assertFalse(isAllowedMiniProgramNavigation("https://evil.test/https://agents.example.com/card", origin))
    }

    @Test
    fun sandboxOriginRejectsAuthoritySmuggling() {
        assertNull(MiniProgramSandboxOrigin.parse("https://agents.example.com@evil.test/card"))
        assertNull(MiniProgramSandboxOrigin.parse("javascript:https://agents.example.com/card"))
        assertNull(MiniProgramSandboxOrigin.parse("file:///android_asset/mini.html"))
    }

    @Test
    fun sandboxOriginNormalizesDefaultPorts() {
        val origin = MiniProgramSandboxOrigin.parse("https://agents.example.com:443/card")

        assertNotNull(origin)
        assertEquals("https://agents.example.com", origin?.origin)
        assertTrue(isAllowedMiniProgramNavigation("https://agents.example.com/card", origin))
        assertFalse(isAllowedMiniProgramNavigation("http://agents.example.com/card", origin))
    }

    @Test
    fun bridgeNavigationRequiresMainFrameAndBridgeAuthority() {
        val bridgeURL = "burnbar-host://invoke?payload=%7B%7D"

        assertTrue(shouldHandleMiniProgramBridgeNavigation(bridgeURL, isForMainFrame = true))
        assertFalse(shouldHandleMiniProgramBridgeNavigation(bridgeURL, isForMainFrame = false))
        assertFalse(shouldHandleMiniProgramBridgeNavigation("burnbar-host://other?payload=%7B%7D", true))
        assertFalse(shouldHandleMiniProgramBridgeNavigation("burnbar-host://attacker@invoke?payload=%7B%7D", true))
    }

    @Test
    fun hostHtmlEscapesAttributesAndFailsClosedForInvalidSandboxURL() {
        val html =
            miniProgramHostHtml(
                sandboxURL = "https://agents.example.com/card\" onload=\"alert(1)",
                csp = "default-src 'self'; frame-ancestors \"bad\" <bad>",
            )

        assertTrue(html.contains("src=\"about:blank\""))
        assertFalse(html.contains("onload=\"alert"))
        assertTrue(html.contains("&quot;bad&quot; &lt;bad&gt;"))
    }

    @Test
    fun hostHtmlPinsPostMessageBridgeToSandboxOrigin() {
        val html =
            miniProgramHostHtml(
                sandboxURL = "https://agents.example.com/card",
                csp = contentSecurityPolicy("https://agents.example.com/card"),
            )

        val normalizedHtml = html.replace("\\/", "/")

        assertTrue(normalizedHtml.contains("var bridgeOrigin = \"https://agents.example.com\";"))
        assertTrue(normalizedHtml.contains("if (event.origin !== bridgeOrigin) return;"))
        assertTrue(normalizedHtml.contains("data.type !== 'burnbar-host-invoke'"))
    }
}
