import type { WebSocket } from "ws";
import { RelayLimitError } from "./errors.js";
import {
  assertFrameForUid,
  assertRoleCanSend,
  assertRequestFrame,
  DEFAULT_RELAY_RUNTIME,
  hostControlChannel,
  hostPresenceKey,
  MAX_RELAY_ERROR_LENGTH,
  normalizeRuntime,
  parseFrame,
  reqChannel,
  respChannel,
  serializeFrame,
  type HermesRealtimeFrame,
  type HermesRelayRuntime,
  type HermesRelaySocketRole,
} from "./protocol.js";
import type { RelayQuotaStore } from "./quota.js";
import { NoopRelayQuotaStore } from "./quota.js";
import type { RelayMessageBus } from "./redisHub.js";

const MAX_CLOSE_REASON_BYTES = 120;

export interface RelaySocket {
  send(data: string): void;
  close(code?: number, reason?: string): void;
  on(event: "message", listener: (data: Buffer) => void): unknown;
  on(event: "close", listener: () => void): unknown;
  on(event: "error", listener: (error: Error) => void): unknown;
}

export interface RelayDependencies {
  bus: RelayMessageBus;
  quota?: RelayQuotaStore;
  uid: string;
  role: HermesRelaySocketRole;
  sessionID: string;
  maxFrameBytes: number;
  presenceTTLSeconds?: number;
}

export class HermesRealtimeRelaySession {
  private readonly presenceTTLSeconds: number;
  private readonly quota: RelayQuotaStore;
  private registeredHostConnectionId: string | undefined;
  private registeredRuntime: HermesRelayRuntime | undefined;
  private boundRuntime: HermesRelayRuntime | undefined;
  private subscribedChannels = new Set<string>();
  private unsubscribeCallbacks: Array<() => Promise<void>> = [];
  private activeRequestRuntimes = new Map<string, HermesRelayRuntime>();
  private presenceTimer: NodeJS.Timeout | undefined;
  private leaseTimer: NodeJS.Timeout | undefined;
  private closed = false;

  constructor(
    private readonly socket: RelaySocket,
    private readonly deps: RelayDependencies
  ) {
    this.presenceTTLSeconds = deps.presenceTTLSeconds ?? 45;
    this.quota = deps.quota ?? new NoopRelayQuotaStore();
  }

  start(): void {
    this.socket.on("message", (data) => {
      this.handleClientMessage(data).catch((error) => {
        this.handleSessionError(error);
      });
    });
    this.socket.on("close", () => {
      this.cleanup().catch(() => undefined);
    });
    this.socket.on("error", () => {
      this.cleanup().catch(() => undefined);
    });
    this.leaseTimer = setInterval(() => {
      this.refreshQuotaLeases().catch(() => undefined);
    }, 30_000);
    this.leaseTimer.unref?.();
  }

  private async handleClientMessage(data: Buffer): Promise<void> {
    const frameByteLength = data.byteLength;
    await this.quota.checkFrameBytes(this.deps.uid, frameByteLength);
    const frame = parseFrame(data, this.deps.maxFrameBytes);
    const runtime = this.frameRuntime(frame);
    await this.bindRuntime(runtime);
    await this.quota.checkFrameBytes(this.deps.uid, frameByteLength, runtime);
    assertFrameForUid(frame, this.deps.uid);
    assertRoleCanSend(frame, this.deps.role);

    switch (frame.type) {
      case "host.register":
        await this.registerHost(frame);
        return;
      case "request.start":
      case "request.cancel":
        assertRequestFrame(frame);
        if (frame.type === "request.start") {
          await this.quota.checkRequestStart(frame.uid, runtime);
          await this.quota.reserveInFlight(frame.uid, frame.requestId!, runtime);
          this.activeRequestRuntimes.set(frame.requestId!, runtime);
        } else if (frame.requestId) {
          await this.releaseInFlight(frame.requestId);
        }
        {
          await this.subscribe(respChannel(frame.uid, frame.requestId!, runtime));
          const subscriberCount = await this.deps.bus.publish(
            reqChannel(frame.uid, frame.connectionId, runtime),
            serializeFrame(frame)
          );
          if (frame.type === "request.start" && typeof subscriberCount === "number" && subscriberCount === 0) {
            await this.releaseInFlight(frame.requestId!, runtime);
            this.sendError(new Error(`Realtime ${runtimeDisplayName(runtime)} host is not connected.`), frame);
          }
        }
        return;
      case "response.chunk":
      case "response.complete":
      case "response.error":
        if (!frame.requestId) throw new Error("requestId is required.");
        if (this.registeredHostConnectionId !== frame.connectionId) {
          throw new Error("Host response is not bound to this relay connection.");
        }
        await this.deps.bus.publish(
          respChannel(frame.uid, frame.requestId, runtime),
          serializeFrame(frame)
        );
        return;
      case "ping":
        this.socket.send(serializeFrame({ ...frame, type: "pong" }));
        return;
      case "host.ready":
      case "pong":
        return;
    }
  }

  private async registerHost(frame: HermesRealtimeFrame): Promise<void> {
    if (this.registeredHostConnectionId && this.registeredHostConnectionId !== frame.connectionId) {
      throw new Error("Host socket is already registered for another relay connection.");
    }
    this.registeredHostConnectionId = frame.connectionId;
    this.registeredRuntime = this.frameRuntime(frame);
    await this.subscribe(reqChannel(frame.uid, frame.connectionId, this.registeredRuntime));
    await this.subscribeControl(hostControlChannel(frame.uid, frame.connectionId, this.registeredRuntime));
    await this.refreshPresence();
    await this.deps.bus.publish(
      hostControlChannel(frame.uid, frame.connectionId, this.registeredRuntime),
      JSON.stringify({ type: "host.replace", sessionID: this.deps.sessionID })
    );
    this.presenceTimer = setInterval(() => {
      this.refreshPresence().catch(() => undefined);
    }, Math.max(5_000, Math.floor(this.presenceTTLSeconds * 500)));
    this.presenceTimer.unref?.();
    this.socket.send(serializeFrame({
      type: "host.ready",
      uid: frame.uid,
      connectionId: frame.connectionId,
      protocolVersion: frame.protocolVersion,
      runtime: this.registeredRuntime,
      payload: { capabilities: frame.payload?.capabilities ?? [] },
    }));
  }

  private async refreshPresence(): Promise<void> {
    if (!this.registeredHostConnectionId) return;
    await this.deps.bus.set(
      hostPresenceKey(this.deps.uid, this.registeredHostConnectionId, this.registeredRuntime ?? DEFAULT_RELAY_RUNTIME),
      JSON.stringify({ sessionID: this.deps.sessionID, observedAt: Date.now() }),
      "EX",
      this.presenceTTLSeconds
    );
  }

  private frameRuntime(frame: HermesRealtimeFrame): HermesRelayRuntime {
    if (frame.runtime === undefined && this.boundRuntime) return this.boundRuntime;
    return normalizeRuntime(frame.runtime);
  }

  private async bindRuntime(runtime: HermesRelayRuntime): Promise<void> {
    if (this.boundRuntime === runtime) return;
    if (this.boundRuntime) {
      throw new Error("Relay socket runtime cannot change after registration.");
    }
    this.boundRuntime = runtime;
    await this.quota.reserveRuntimeSocket(this.deps.uid, this.deps.role, this.deps.sessionID, runtime);
  }

  private async refreshQuotaLeases(): Promise<void> {
    await this.quota.refreshSocket(this.deps.uid, this.deps.role, this.deps.sessionID);
    if (this.boundRuntime) {
      await this.quota.refreshRuntimeSocket(this.deps.uid, this.deps.role, this.deps.sessionID, this.boundRuntime);
    }
  }

  private async subscribe(channel: string): Promise<void> {
    if (this.subscribedChannels.has(channel)) return;
    const unsubscribe = await this.deps.bus.subscribe(channel, (message) => {
      this.observeOutboundFrame(message).catch(() => undefined);
      this.socket.send(message);
    });
    this.unsubscribeCallbacks.push(unsubscribe);
    this.subscribedChannels.add(channel);
  }

  private async subscribeControl(channel: string): Promise<void> {
    if (this.subscribedChannels.has(channel)) return;
    const unsubscribe = await this.deps.bus.subscribe(channel, (message) => {
      this.handleControlMessage(message);
    });
    this.unsubscribeCallbacks.push(unsubscribe);
    this.subscribedChannels.add(channel);
  }

  private handleControlMessage(message: string): void {
    try {
      const parsed = JSON.parse(message) as { type?: string; sessionID?: string };
      if (parsed.type === "host.replace" && parsed.sessionID && parsed.sessionID !== this.deps.sessionID) {
        this.socket.close(4000, "Hermes host replaced by a newer session.");
      }
    } catch {
      this.socket.close(1008, "Malformed Hermes relay control frame.");
    }
  }

  private async observeOutboundFrame(message: string): Promise<void> {
    let frame: HermesRealtimeFrame;
    try {
      frame = JSON.parse(message) as HermesRealtimeFrame;
    } catch {
      return;
    }
    if ((frame.type === "response.complete" || frame.type === "response.error") && frame.requestId) {
      await this.releaseInFlight(frame.requestId, this.frameRuntime(frame));
    }
  }

  private async releaseInFlight(requestID: string, runtime?: HermesRelayRuntime): Promise<void> {
    const requestRuntime = this.activeRequestRuntimes.get(requestID) ?? runtime ?? this.boundRuntime ?? DEFAULT_RELAY_RUNTIME;
    this.activeRequestRuntimes.delete(requestID);
    await this.quota.releaseInFlight(this.deps.uid, requestID, requestRuntime);
  }

  private sendError(error: unknown, frame?: HermesRealtimeFrame): void {
    const message = truncateUtf8(
      error instanceof Error ? error.message : "Realtime relay error.",
      MAX_RELAY_ERROR_LENGTH
    );
    this.socket.send(serializeFrame({
      type: "response.error",
      uid: this.deps.uid,
      connectionId: frame?.connectionId ?? this.registeredHostConnectionId ?? "unknown",
      requestId: frame?.requestId,
      protocolVersion: 1,
      runtime: frame ? this.frameRuntime(frame) : this.boundRuntime,
      payload: { error: message },
    }));
  }

  private handleSessionError(error: unknown): void {
    this.sendError(error);
    const closeCode = error instanceof RelayLimitError ? 1013 : 1008;
    this.socket.close(
      closeCode,
      truncateUtf8(error instanceof Error ? error.message : "Hermes realtime relay error.", MAX_CLOSE_REASON_BYTES)
    );
  }

  private async cleanup(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    if (this.presenceTimer) clearInterval(this.presenceTimer);
    if (this.leaseTimer) clearInterval(this.leaseTimer);
    await Promise.allSettled(this.unsubscribeCallbacks.map((unsubscribe) => unsubscribe()));
    this.unsubscribeCallbacks = [];
    this.subscribedChannels.clear();
    await Promise.allSettled(
      [...this.activeRequestRuntimes].map(([requestID, runtime]) =>
        this.quota.releaseInFlight(this.deps.uid, requestID, runtime)
      )
    );
    this.activeRequestRuntimes.clear();
    if (this.registeredHostConnectionId) {
      await this.deps.bus.del(hostPresenceKey(
        this.deps.uid,
        this.registeredHostConnectionId,
        this.registeredRuntime ?? DEFAULT_RELAY_RUNTIME
      ));
    }
    if (this.boundRuntime) {
      await this.quota.releaseRuntimeSocket(
        this.deps.uid,
        this.deps.role,
        this.deps.sessionID,
        this.boundRuntime
      );
    }
    await this.quota.releaseSocket(this.deps.uid, this.deps.role, this.deps.sessionID);
  }
}

export function isOpenSocket(socket: WebSocket): boolean {
  return socket.readyState === socket.OPEN;
}

function truncateUtf8(value: string, maxBytes: number): string {
  if (Buffer.byteLength(value, "utf8") <= maxBytes) return value;
  let output = "";
  for (const character of value) {
    const next = output + character;
    if (Buffer.byteLength(next, "utf8") > maxBytes) break;
    output = next;
  }
  return output;
}

function runtimeDisplayName(runtime: HermesRelayRuntime): string {
  return runtime === "pi" ? "Pi" : "Hermes";
}
