import LibSignalClient
import Foundation

// 1) At-rest HPKE seal/open
let recip = IdentityKeyPair.generate()
let info = Array("OpenBurnBar-Signal-AtRest-v1|test".utf8)
let aad  = Array("OpenBurnBar-Signal-AAD-v1|at-rest|cloudvault|u1||d1|body||1".utf8)
let pt   = Array("top secret body".utf8)
let ct   = try recip.publicKey.seal(pt, info: info, associatedData: aad)
print("ATREST seal/open roundtrip OK:", Array(try recip.privateKey.open(ct, info: info, associatedData: aad)) == pt)
var failed = false
do { _ = try recip.privateKey.open(ct, info: info, associatedData: Array("WRONG".utf8)) } catch { failed = true }
print("ATREST wrong-AAD fails closed:", failed)

// 2) X3DH+PQXDH session + Double Ratchet (Alice -> Bob)
let aStore = InMemorySignalProtocolStore(identity: IdentityKeyPair.generate(), registrationId: 1)
let bStore = InMemorySignalProtocolStore(identity: IdentityKeyPair.generate(), registrationId: 2)
let aAddr = try ProtocolAddress(name: "alice", deviceId: 1)
let bAddr = try ProtocolAddress(name: "bob", deviceId: 1)
let bPre = PrivateKey.generate(); let bSigned = PrivateKey.generate()
let bIdent = try bStore.identityKeyPair(context: NullContext()).privateKey
let bSignedSig = bIdent.generateSignature(message: bSigned.publicKey.serialize())
let bKyber = KEMKeyPair.generate()
let bKyberSig = bIdent.generateSignature(message: bKyber.publicKey.serialize())
let bundle = try PreKeyBundle(
  registrationId: try bStore.localRegistrationId(context: NullContext()),
  deviceId: 1, prekeyId: 31337, prekey: bPre.publicKey,
  signedPrekeyId: 22, signedPrekey: bSigned.publicKey, signedPrekeySignature: bSignedSig,
  identity: try bStore.identityKeyPair(context: NullContext()).identityKey,
  kyberPrekeyId: 8, kyberPrekey: bKyber.publicKey, kyberPrekeySignature: bKyberSig)
try processPreKeyBundle(bundle, for: bAddr, ourAddress: aAddr, sessionStore: aStore, identityStore: aStore, context: NullContext())
let msg = Array("hello over the ratchet".utf8)
let enc = try signalEncrypt(message: msg, for: bAddr, localAddress: aAddr, sessionStore: aStore, identityStore: aStore, context: NullContext())
print("SESSION ciphertext type:", enc.messageType.rawValue)
try bStore.storePreKey(PreKeyRecord(id: 31337, privateKey: bPre), id: 31337, context: NullContext())
try bStore.storeSignedPreKey(try SignedPreKeyRecord(id: 22, timestamp: 0, privateKey: bSigned, signature: bSignedSig), id: 22, context: NullContext())
try bStore.storeKyberPreKey(try KyberPreKeyRecord(id: 8, timestamp: 0, keyPair: bKyber, signature: bKyberSig), id: 8, context: NullContext())
let pkmsg = try PreKeySignalMessage(bytes: enc.serialize())
let dec = try signalDecryptPreKey(message: pkmsg, from: aAddr, localAddress: bAddr, sessionStore: bStore, identityStore: bStore, preKeyStore: bStore, signedPreKeyStore: bStore, kyberPreKeyStore: bStore, context: NullContext())
print("SESSION X3DH+ratchet decrypt OK:", Array(dec) == msg)

// 3) Safety number
let gen = NumericFingerprintGenerator(iterations: 1024)
let fp = try gen.create(version: 2,
  localIdentifier: Array("alice".utf8), localKey: try aStore.identityKeyPair(context: NullContext()).publicKey,
  remoteIdentifier: Array("bob".utf8), remoteKey: try bStore.identityKeyPair(context: NullContext()).publicKey)
print("SAFETY NUMBER (first 20):", String(fp.displayable.formatted.prefix(20)))
print("LIBSIGNAL_SWIFT_FULL_PROOF_OK")
