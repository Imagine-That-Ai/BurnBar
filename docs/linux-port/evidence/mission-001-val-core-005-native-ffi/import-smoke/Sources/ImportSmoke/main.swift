import Foundation
import LibSignalClient
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohFFI
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
import OpenBurnBarSignalCore
import OpenBurnBarSignalSessionTransport

let signalPrivateKey = PrivateKey.generate()
let plaintext = Data("val-core-005-libsignal-roundtrip".utf8)
let aad = Data("val-core-005-aad".utf8)
let sealed = signalPrivateKey.publicKey.seal(
    plaintext,
    info: "OpenBurnBar VAL-CORE-005 Linux import smoke",
    associatedData: aad
)
let opened = try signalPrivateKey.open(
    sealed,
    info: "OpenBurnBar VAL-CORE-005 Linux import smoke",
    associatedData: aad
)
precondition(opened == plaintext)

let signalIdentity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "linux-peer")
precondition(!signalIdentity.publicKeyBase64.isEmpty)

let protocolVersion = openburnbarIrohProtocolVersion()
precondition(protocolVersion > 0)

let canonicalNode = IrohNodeIdNormalization.canonical(" NODE-ABC ")
precondition(canonicalNode == "node-abc")

let mediaKey = MediaFrameAEAD().deriveSessionKey(
    sharedSecret: Data(repeating: 7, count: 32),
    salt: Data("linux-media-session".utf8)
)
_ = mediaKey

precondition(ComputerUseDenyReason.killSwitch.rawValue == "kill_switch")

print("VAL-CORE-005 import smoke ok signal=\(sealed.count) iroh=\(protocolVersion)")
