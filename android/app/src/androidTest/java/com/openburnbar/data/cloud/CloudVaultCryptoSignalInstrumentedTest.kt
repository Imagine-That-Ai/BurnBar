package com.openburnbar.data.cloud

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.firebase.installations.FirebaseInstallations
import com.google.firebase.remoteconfig.FirebaseRemoteConfig
import com.google.firebase.remoteconfig.FirebaseRemoteConfigSettings
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

private const val SIGNAL_DEVICE_KAT_PRIVATE_KEY_B64 = "yGZ5zfds7ljkjsopcLya1ayDbjV+TCL6/b4BQBpqfV0="
private const val SIGNAL_DEVICE_KAT_PUBLIC_KEY_B64_CANONICAL = "BVw7AC8duGgSdz/wLmMLMe+ymSUCcMkOcoJ+E6Eb+RhO"
private const val SIGNAL_DEVICE_KAT_CIPHERTEXT_B64 = "AQt/WxZMem2jpwxChzbQuzg/yMY5kdPdzuOmgLoJwoIZOFUfdEr33hTkLyIzwQTD7J2uShoruECN2ty8j1QlSe2siO6trszlngaJe7Zhb7liPArb1x/A+J/nrS5GNw=="
private const val SIGNAL_DEVICE_KAT_PLAINTEXT_B64 = "Y3Jvc3MtbGFuZ3VhZ2UgaW50ZXJvcCBzZWNyZXQg4oCUIG5vZGUgc2VhbGVk"

@RunWith(AndroidJUnit4::class)
class CloudVaultCryptoSignalInstrumentedTest {
    @Test
    fun signalAtRestLibsignalOpensNodeKatAndRejectsRelocationOnDevice() {
        val privateKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_DEVICE_KAT_PRIVATE_KEY_B64)
        val binding = signalBinding(docId = "doc-42", field = "body")

        val plaintext = CloudVaultCryptoSupport.decodeBase64(SIGNAL_DEVICE_KAT_PLAINTEXT_B64)
        val ciphertext = CloudVaultCryptoSupport.decodeBase64(SIGNAL_DEVICE_KAT_CIPHERTEXT_B64)

        assertArrayEquals(plaintext, CloudVaultCryptoSupport.atRestOpen(ciphertext, privateKey, binding))
        assertTrue(
            "relocated docId must fail closed on physical Android/libsignal",
            runCatching {
                CloudVaultCryptoSupport.atRestOpen(
                    ciphertext,
                    privateKey,
                    binding.copy(docId = "relocated-doc"),
                )
            }.isFailure,
        )
    }

    @Test
    fun signalCloudVaultEnvelopeRoundTripsAndRejectsExpectedBindingMismatchOnDevice() {
        val privateKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_DEVICE_KAT_PRIVATE_KEY_B64)
        val publicKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_DEVICE_KAT_PUBLIC_KEY_B64_CANONICAL)
        val binding = cloudBinding(docId = "android-physical-doc", field = "signalEnvelope")
        val plaintext = """{"device":"android","signal":true}""".toByteArray()

        val envelope =
            CloudVaultCrypto.sealSignalPayload(
                plaintext = plaintext,
                recipients = listOf(CloudVaultSignalRecipient("device", "android-device-key-v1", publicKey)),
                binding = binding,
            )

        assertEquals(binding, envelope.binding)
        assertArrayEquals(
            plaintext,
            CloudVaultCrypto.openSignalPayload(
                envelope = envelope,
                recipientIdentityKeyId = "android-device-key-v1",
                recipientIdentityPrivateKey = privateKey,
                expectedBinding = binding,
            ),
        )
        assertTrue(
            "high-level opener must reject caller/envelope binding mismatch on physical Android/libsignal",
            runCatching {
                CloudVaultCrypto.openSignalPayload(
                    envelope = envelope,
                    recipientIdentityKeyId = "android-device-key-v1",
                    recipientIdentityPrivateKey = privateKey,
                    expectedBinding = cloudBinding(docId = "relocated-doc", field = "signalEnvelope"),
                )
            }.isFailure,
        )
    }

    @Test
    fun signalPhysicalMatrixAndroidEmitsEnvelopeForMacToAppFiles() {
        val macRecipient = org.signal.libsignal.protocol.ecc.ECKeyPair.generate()
        val binding = cloudBinding(docId = "android-to-mac-thread", field = "signalEnvelope")
        val plaintext = "physical-matrix android-to-mac at-rest payload"
        val envelope =
            CloudVaultCrypto.sealSignalPayload(
                plaintext = plaintext.toByteArray(),
                recipients =
                    listOf(
                        CloudVaultSignalRecipient(
                            recipientKind = "device",
                            recipientIdentityKeyId = "physical-mac-device_1",
                            publicKeyData = macRecipient.publicKey.serialize(),
                        ),
                    ),
                binding = binding,
            )

        val vector =
            JSONObject()
                .put("producer", "android")
                .put("consumer", "mac")
                .put("recipientIdentityKeyId", "physical-mac-device_1")
                .put("recipientPrivateKeyB64", CloudVaultCryptoSupport.encodeBase64(macRecipient.privateKey.serialize()))
                .put("plaintext", plaintext)
                .put(
                    "binding",
                    JSONObject(
                        mapOf(
                            "uid" to binding.uid,
                            "scope" to binding.scope,
                            "collection" to binding.collection,
                            "docId" to binding.docId,
                            "field" to binding.field,
                            "mode" to binding.mode,
                            "formatVersion" to binding.formatVersion,
                        ),
                    ),
                )
                .put("envelope", jsonValue(CloudVaultCrypto.signalEnvelopeMap(envelope)))

        val encoded = CloudVaultCryptoSupport.encodeBase64(vector.toString().toByteArray(Charsets.UTF_8))
        Log.i("SignalPhysicalMatrix", "SIGNAL_MATRIX_ANDROID_TO_MAC_V1 $encoded")
        println("SIGNAL_MATRIX_ANDROID_TO_MAC_V1 $encoded")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.filesDir, "signal-matrix-android-to-mac.b64").writeText(encoded)
    }

    @Test
    fun signalRemoteConfigCanaryProbeReportsInstallationAndGate() {
        val args = InstrumentationRegistry.getArguments()
        val expectedGate = args.getString("expectedSignalGate")
        val installationId = Tasks.await(FirebaseInstallations.getInstance().id)
        val remoteConfig = FirebaseRemoteConfig.getInstance()
        Tasks.await(
            remoteConfig.setConfigSettingsAsync(
                FirebaseRemoteConfigSettings.Builder()
                    .setMinimumFetchIntervalInSeconds(0)
                    .build(),
            ),
        )
        var activated = false
        var fetchError: String? = null
        runCatching {
            activated = Tasks.await(remoteConfig.fetchAndActivate())
        }.onFailure { error ->
            fetchError = error::class.java.simpleName + ": " + (error.message ?: "Remote Config fetch failed")
        }
        val domainID = "conversations_chat"
        val domainKey = AndroidCloudVaultSignalPayloads.signalAtRestRemoteConfigKey(domainID)
        val disabled = remoteConfig.getBoolean(AndroidCloudVaultSignalPayloads.SIGNAL_AT_REST_DISABLED_REMOTE_CONFIG_KEY)
        val domainEnabled = remoteConfig.getBoolean(domainKey)
        val effectiveEnabled = AndroidCloudVaultSignalPayloads.signalSealingIsEnabled(domainID)

        val marker =
            "SIGNAL_RC_ANDROID_GATE_V1 fid=$installationId activated=$activated disabled=$disabled " +
                "domainKey=$domainKey domainEnabled=$domainEnabled effectiveEnabled=$effectiveEnabled " +
                "fetchError=${fetchError ?: "none"}"
        Log.i("SignalPhysicalMatrix", marker)
        println(marker)

        when (expectedGate) {
            "true" -> {
                assertTrue("Remote Config fetch must succeed before asserting targeted canary", fetchError == null)
                assertTrue("targeted Remote Config canary should enable Signal gate", effectiveEnabled)
            }
            "false" -> {
                assertTrue("Remote Config fetch must succeed before asserting rollback", fetchError == null)
                assertTrue("rollback kill switch should disable Signal gate", !effectiveEnabled)
            }
        }
    }

    @Test
    fun firebaseInstallationsRestCreateSucceedsFromDeviceProcess() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val apiKey = context.getString(context.resources.getIdentifier("google_api_key", "string", context.packageName))
        val appId = context.getString(context.resources.getIdentifier("google_app_id", "string", context.packageName))
        val projectNumber = context.getString(context.resources.getIdentifier("gcm_defaultSenderId", "string", context.packageName))
        val fid = "c" + UUID.randomUUID().toString().replace("-", "").take(21)
        val body = JSONObject()
            .put("fid", fid)
            .put("appId", appId)
            .put("authVersion", "FIS_v2")
            .put("sdkVersion", "a:19.0.0")
            .toString()

        val connection = (URL("https://firebaseinstallations.googleapis.com/v1/projects/$projectNumber/installations")
            .openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15_000
            readTimeout = 15_000
            doOutput = true
            setRequestProperty("x-goog-api-key", apiKey)
            setRequestProperty("Content-Type", "application/json")
        }
        connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }

        val status = connection.responseCode
        val responseBody = runCatching {
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            stream?.bufferedReader()?.use { it.readText() }.orEmpty()
        }.getOrElse { it.message.orEmpty() }
        val marker = "SIGNAL_FIS_REST_ANDROID_V1 status=$status fid=$fid body=${redactFirebaseInstallationResponse(responseBody)}"
        Log.i("SignalPhysicalMatrix", marker)
        println(marker)

        assertEquals("Firebase Installations REST create must succeed from the Android app process", 200, status)
    }

    private fun signalBinding(docId: String, field: String): SignalEnvelopeBinding =
        SignalEnvelopeBinding(
            uid = "u1",
            scope = "cloudvault",
            collection = "pensieve",
            docId = docId,
            field = field,
            mode = "at-rest",
            formatVersion = 1,
        )

    private fun cloudBinding(docId: String, field: String): CloudVaultSignalBinding =
        CloudVaultSignalBinding(
            uid = "android-physical-user",
            collection = "mobile_assistant_chats",
            docId = docId,
            field = field,
        )

    private fun jsonValue(value: Any?): Any =
        when (value) {
            is Map<*, *> -> {
                val json = JSONObject()
                value.forEach { (key, child) -> json.put(key as String, jsonValue(child)) }
                json
            }
            is List<*> -> {
                val json = JSONArray()
                value.forEach { child -> json.put(jsonValue(child)) }
                json
            }
            else -> value ?: JSONObject.NULL
        }

    private fun redactFirebaseInstallationResponse(raw: String): String =
        runCatching {
            val json = JSONObject(raw)
            if (json.has("refreshToken")) {
                json.put("refreshToken", "redacted")
            }
            if (json.has("authToken")) {
                val authToken = json.getJSONObject("authToken")
                json.put(
                    "authToken",
                    JSONObject()
                        .put("token", "redacted")
                        .put("expiresIn", authToken.optString("expiresIn")),
                )
            }
            json.toString()
        }.getOrElse { raw.take(512) }
}
