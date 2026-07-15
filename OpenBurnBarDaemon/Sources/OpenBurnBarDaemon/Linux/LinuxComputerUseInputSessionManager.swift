#if os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

/// Owns the lifetime of Linux system-input grants for daemon Computer Use
/// sessions.  Wayland RemoteDesktop consent is granted once per CU session;
/// subsequent actions reuse the broker-issued handle instead of prompting on
/// every event.  X11/AT-SPI actions continue to use the stateless adapter.
public actor LinuxComputerUseInputSessionManager {
    private let adapter: LinuxComputerUseInputAdapter
    private var waylandSessions: [ComputerUseSessionID: LinuxComputerUseInputAdapter.WaylandRemoteDesktopSession] = [:]

    public init(adapter: LinuxComputerUseInputAdapter = LinuxComputerUseInputAdapter()) {
        self.adapter = adapter
    }

    /// Dispatches an action using the best Linux-native path for the current
    /// desktop.  A Wayland portal grant is created lazily after the daemon's
    /// normal Computer Use approval, then retained until the CU session ends.
    public func dispatch(
        sessionID: ComputerUseSessionID,
        action: MacInputAction
    ) async throws -> BurnBarJSONValue {
        try Task.checkCancellation()

        if let session = waylandSessions[sessionID] {
            do {
                return try await adapter.dispatchWaylandRemoteDesktop(action, session: session)
            } catch {
                // A broker can revoke a grant while a session is active.  Do
                // not retain a stale handle or accidentally reuse it later.
                waylandSessions.removeValue(forKey: sessionID)
                throw error
            }
        }

        let portal = adapter.waylandPortalCapability()
        if portal.isProbeReady {
            let session = try await adapter.startWaylandRemoteDesktopSession()
            waylandSessions[sessionID] = session
            do {
                return try await adapter.dispatchWaylandRemoteDesktop(action, session: session)
            } catch {
                waylandSessions.removeValue(forKey: sessionID)
                try? await adapter.stopWaylandRemoteDesktopSession(session)
                throw error
            }
        }

        // On X11, or on a Wayland desktop with an X11/AT-SPI fallback, the
        // stateless adapter performs the existing capability and kill-switch
        // checks before invoking its fixed command vector.
        return try await adapter.dispatch(action)
    }

    /// Closes a portal grant, if this CU session created one.  Teardown is
    /// best-effort so a panic/kill-switch path never waits on a broker that is
    /// already unavailable.
    public func stop(sessionID: ComputerUseSessionID) async {
        guard let session = waylandSessions.removeValue(forKey: sessionID) else { return }
        _ = try? await adapter.stopWaylandRemoteDesktopSession(session)
    }

    /// Closes every grant.  This is used by global panic, entitlement revoke,
    /// and daemon shutdown paths before their audit records are finalized.
    public func stopAll() async {
        let sessions = Array(waylandSessions.values)
        waylandSessions.removeAll()
        for session in sessions {
            _ = try? await adapter.stopWaylandRemoteDesktopSession(session)
        }
    }

    public func activeWaylandSessionCount() -> Int {
        waylandSessions.count
    }
}
#endif
