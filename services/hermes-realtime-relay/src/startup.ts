import { logError, logEvent } from "./logging.js";

/** The minimal Redis-hub surface the startup readiness check needs. */
export interface PingableHub {
  ping(): Promise<unknown>;
}

/**
 * Verify the relay's core dependency (Redis) is reachable at boot and log the
 * result loudly.
 *
 * Without this, a relay that finishes `listen()` while Redis is unreachable
 * looks healthy in the logs ("relay_listening") even though every request 503s
 * on /readyz and no traffic can actually be served. Surfacing the boot-time
 * Redis state makes the failure explicit for operators and feeds the relay 5xx
 * alert policy, instead of failing silently on the core dependency.
 *
 * @returns true iff Redis answered the ping.
 */
export async function verifyRedisAtStartup(hub: PingableHub): Promise<boolean> {
  try {
    await hub.ping();
    logEvent("relay_redis_ready");
    return true;
  } catch (error) {
    logError("relay_redis_unreachable_at_startup", error);
    return false;
  }
}
