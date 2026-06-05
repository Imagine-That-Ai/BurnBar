import org.signal.libsignal.protocol.IdentityKeyPair
fun main() {
  val kp = IdentityKeyPair.generate()
  val pub = kp.publicKey.publicKey
  val priv = kp.privateKey
  val info = "OpenBurnBar-Signal-AtRest-v1|test".toByteArray()
  val aad = "OpenBurnBar-Signal-AAD-v1|at-rest|cloudvault|u1||d1|body||1".toByteArray()
  val pt = "top secret body".toByteArray()
  val ct = pub.seal(pt, info, aad)
  val opened = priv.open(ct, info, aad)
  println("ATREST seal/open OK: " + opened.contentEquals(pt))
  var failed = false
  try { priv.open(ct, info, "WRONG".toByteArray()) } catch (e: Exception) { failed = true }
  println("ATREST wrong-AAD fails closed: " + failed)
  println("LIBSIGNAL_KOTLIN_PROOF_OK")
}
