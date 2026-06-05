import LibSignalClient
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/SignalEnvelopeV1Vector.json"))
let j = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let priv = try PrivateKey(Array(Data(base64Encoded: j["recipientPrivateKeyB64"] as! String)!))
let info = Array((j["info"] as! String).utf8)
let aad  = Array((j["aad"] as! String).utf8)
let ct   = Array(Data(base64Encoded: j["ciphertextB64"] as! String)!)
let pt   = Data(base64Encoded: j["plaintextB64"] as! String)!
let opened = try priv.open(ct, info: info, associatedData: aad)
print("KAT Node->Swift open OK:", Data(opened) == pt, "->", String(data: Data(opened), encoding: .utf8) ?? "?")
var f = false; do { _ = try priv.open(ct, info: info, associatedData: Array("tampered".utf8)) } catch { f = true }
print("KAT Swift wrong-AAD fails closed:", f)
print("KAT_SWIFT_OK")
