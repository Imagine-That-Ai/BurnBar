package com.openburnbar.data.cloud

import java.math.BigInteger
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp

/**
 * Rejects any escrow public key that is not a canonical affine point on its
 * declared prime-field curve. Shared by the CloudVault trusted-device chain
 * verifier and the escrow device safety-code derivation, so a malformed or
 * off-curve key can never enter either trust computation.
 */
internal fun requireP256Point(publicKey: java.security.PublicKey, context: String) {
    val ecPublicKey = publicKey as? ECPublicKey
        ?: error("$context escrow public key is invalid.")
    val field = ecPublicKey.params.curve.field as? ECFieldFp
        ?: error("$context escrow public key is invalid.")
    val p = field.p
    val x = ecPublicKey.w.affineX
    val y = ecPublicKey.w.affineY
    check(x.signum() >= 0 && y.signum() >= 0 && x < p && y < p) {
        "$context escrow public key is invalid."
    }
    val curve = ecPublicKey.params.curve
    val left = y.modPow(BigInteger.valueOf(2), p)
    val right = x.modPow(BigInteger.valueOf(3), p)
        .add(curve.a.multiply(x))
        .add(curve.b)
        .mod(p)
    check(left == right) {
        "$context escrow public key is invalid."
    }
}
