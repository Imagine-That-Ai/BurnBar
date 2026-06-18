import type { AnalyticsTransport, AnalyticsProps } from './recorder';
import type { AmplitudeServerZone } from './config';

type AmplitudeNodeModule = typeof import('@amplitude/analytics-node');
type NodeClient = ReturnType<AmplitudeNodeModule['createInstance']>;

/**
 * Production transport backed by the Amplitude Node SDK, mirroring
 * AgentLens/Services/Analytics/AmplitudeTransport.swift and
 * website/src/lib/analytics/amplitudeTransport.ts. The SDK is **dynamically
 * imported on start()** — which the recorder calls only after consent — so a
 * pre-consent extension host loads zero Amplitude code and makes zero network
 * calls.
 *
 * The Node SDK is server-side: it has NO autocapture, NO default tracking, NO
 * remote-config fetch, and NO device/geo fingerprinting (those are browser-only
 * concerns), so nothing can fire off-taxonomy or bypass the gate by construction.
 * IP is stripped server-side; identity is an anonymous random per-install UUID
 * passed explicitly as `device_id` on EVERY event (the Node client has no
 * `setDeviceId`), never a hostname or hardware id, and `user_id` is pinned
 * `undefined` (the extension has no authenticated sign-in). With no key it never
 * loads.
 *
 * We use `createInstance()` (an ISOLATED client), never the package-level
 * singleton, so this transport owns the only Amplitude state in the process and
 * `stop()` can fully tear it down by dropping the reference.
 */
export class AmplitudeTransport implements AnalyticsTransport {
  private amp: NodeClient | null = null;
  private started = false;
  private optedOut = false;
  private queue: { name: string; category: string; props: AnalyticsProps }[] = [];

  constructor(
    private readonly deviceId: string,
    private readonly serverZone: AmplitudeServerZone = 'US'
  ) {}

  get isStarted(): boolean {
    return this.started;
  }

  start(apiKey: string): void {
    if (this.started || apiKey.length === 0) return;
    this.started = true;
    this.optedOut = false;

    // Re-grant after a prior revoke: the module is already loaded — just
    // re-enable and flush, never re-init.
    if (this.amp) {
      this.amp.setOptOut(false);
      this.flush(this.amp);
      return;
    }

    import('@amplitude/analytics-node')
      .then((mod) => {
        const client = mod.createInstance();
        // init returns AmplitudeReturn<void> ({ promise }); we don't await it —
        // the SDK queues until ready. No autocapture/defaultTracking/remoteConfig
        // options exist on the Node SDK (nothing to disable; dark by default).
        client.init(apiKey, {
          instanceName: 'openburnbar-extension',
          serverZone: this.serverZone,
          optOut: false,
          useBatch: false,
          flushQueueSize: 30,
          flushIntervalMillis: 30_000,
          // Allow short custom ids; our device_id is a 36-char UUID anyway. The
          // device_id is attached per-event in send() (the Node client exposes no
          // setDeviceId), so this just keeps the SDK from rejecting it.
          minIdLength: 1
        });
        this.amp = client;
        if (!this.optedOut) this.flush(client);
      })
      .catch(() => {
        // SDK failed to load — stay dark, drop the queue, never throw into the host.
        this.started = false;
        this.queue = [];
      });
  }

  track(name: string, category: string, props: AnalyticsProps): void {
    if (!this.started || this.optedOut) return;
    if (this.amp) this.send(this.amp, name, category, props);
    else this.queue.push({ name, category, props });
  }

  stop(): void {
    this.optedOut = true;
    this.started = false;
    this.queue = [];
    if (this.amp) {
      this.amp.setOptOut(true); // belt-and-suspenders: drop anything in flight
      this.amp = null; // drop the client; flush nothing. A future start() re-inits.
    }
  }

  private flush(client: NodeClient): void {
    const pending = this.queue;
    this.queue = [];
    for (const e of pending) this.send(client, e.name, e.category, e.props);
  }

  private send(client: NodeClient, name: string, category: string, props: AnalyticsProps): void {
    // Attach the anonymous device id per-event AND pin user_id undefined so the
    // SDK can never derive identity from the host/process.
    client.track(name, { ...props, event_category: category }, { device_id: this.deviceId, user_id: undefined });
  }
}
