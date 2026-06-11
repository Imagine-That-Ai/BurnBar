import Foundation
import OpenBurnBarComputerUseCore

/// Canonical OpenBurnBar signing identity for privileged-socket peer checks.
///
/// The definition moved to `OpenBurnBarPrivilegedTrust` in
/// `OpenBurnBarComputerUseCore` so that socket *clients* (app, bridge) can run
/// the same server-authentication checks the daemons run on accepted peers —
/// both halves of every privileged connection now share one trust source.
/// This alias keeps the daemon-side name stable for existing call sites.
public typealias OpenBurnBarSigningIdentity = OpenBurnBarPrivilegedTrust
