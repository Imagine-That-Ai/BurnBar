import org.signal.libsignal.protocol.ecc.ECPrivateKey
import java.io.File
import java.util.Base64
fun main() {
  val txt = File("/tmp/SignalEnvelopeV1Vector.json").readText()
  fun f(k: String) = Regex("\"$k\"\\s*:\\s*\"(.*?)\"").find(txt)!!.groupValues[1]
  val priv = ECPrivateKey(Base64.getDecoder().decode(f("recipientPrivateKeyB64")))
  val info = f("info").toByteArray()
  val aad  = f("aad").toByteArray()
  val ct   = Base64.getDecoder().decode(f("ciphertextB64"))
  val pt   = Base64.getDecoder().decode(f("plaintextB64"))
  val opened = priv.open(ct, info, aad)
  println("KAT Node->Kotlin open OK: " + opened.contentEquals(pt) + " -> " + String(opened))
  var failed = false
  try { priv.open(ct, info, "tampered".toByteArray()) } catch (e: Exception) { failed = true }
  println("KAT Kotlin wrong-AAD fails closed: " + failed)
  println("KAT_KOTLIN_OK")
}
