package com.openburnbar

import java.nio.file.Files
import java.nio.file.Path
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Document
import org.w3c.dom.Element

class AndroidBackupPolicyTest {
    private val projectDir: Path = Path.of(System.getProperty("user.dir"))
    private val androidNamespace = "http://schemas.android.com/apk/res/android"
    private val backupDomains = setOf(
        "root",
        "file",
        "database",
        "sharedpref",
        "external",
        "device_root",
        "device_file",
        "device_database",
        "device_sharedpref",
    )

    @Test
    fun `manifest disables platform backup and points at extraction rules`() {
        val manifest = parseXml(projectDir.resolve("src/main/AndroidManifest.xml"))
        val application = manifest.documentElement.elements("application").single()

        assertEquals("false", application.getAttributeNS(androidNamespace, "allowBackup"))
        assertEquals("@xml/data_extraction_rules", application.getAttributeNS(androidNamespace, "dataExtractionRules"))
        assertEquals("false", application.getAttributeNS(androidNamespace, "fullBackupContent"))
    }

    @Test
    fun `data extraction rules exclude every backup domain from cloud and device transfer`() {
        val rules = parseXml(projectDir.resolve("src/main/res/xml/data_extraction_rules.xml"))

        assertBackupSectionExcludesAllDomains(rules, "cloud-backup")
        assertBackupSectionExcludesAllDomains(rules, "device-transfer")
        assertEquals(0, rules.documentElement.elements("include").size)
    }

    private fun assertBackupSectionExcludesAllDomains(rules: Document, sectionName: String) {
        val section = rules.documentElement.elements(sectionName).single()
        val excludes = section.elements("exclude")
        val domains = excludes.map { it.getAttribute("domain") }.toSet()

        assertEquals(backupDomains, domains)
        assertEquals(backupDomains.size, excludes.size)
        assertTrue("$sectionName must exclude the whole domain subtree", excludes.all { it.getAttribute("path") == "." })
        assertFalse("$sectionName must use Android 12+ device-protected domain names", domains.any { it.startsWith("device_protected_") })
    }

    private fun parseXml(path: Path): Document {
        assertTrue("Missing XML fixture at $path", Files.isRegularFile(path))
        val factory = DocumentBuilderFactory.newInstance()
        factory.isNamespaceAware = true
        val document = factory.newDocumentBuilder().parse(path.toFile())
        assertNotNull(document.documentElement)
        return document
    }

    private fun Element.elements(name: String): List<Element> {
        val nodes = getElementsByTagName(name)
        return (0 until nodes.length).mapNotNull { index ->
            val node = nodes.item(index)
            if (node is Element) node else null
        }
    }
}
