package com.openburnbar.test

import java.security.PublicKey
import java.security.interfaces.ECPublicKey
import org.json.JSONArray

fun ecPublicKey(publicKey: PublicKey): ECPublicKey {
    val key = publicKey as? ECPublicKey
    check(key != null) { "Expected EC public key, got $publicKey" }
    return key
}

fun requireJsonArray(value: Any): JSONArray {
    val array = value as? JSONArray
    check(array != null) { "Expected JSONArray, got $value" }
    return array
}

fun requireClassLoaderResourceText(loader: ClassLoader?, resourcePath: String): String {
    val resolvedLoader = requireNotNull(loader) { "Missing class loader" }
    val stream = requireNotNull(resolvedLoader.getResourceAsStream(resourcePath)) {
        "Missing resource: $resourcePath"
    }
    return stream.bufferedReader().use { it.readText() }
}
