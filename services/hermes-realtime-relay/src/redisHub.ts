import { Redis } from "ioredis";

export interface RelayMessageBus {
  publish(channel: string, message: string): Promise<number>;
  subscribe(channel: string, listener: (message: string) => void): Promise<() => Promise<void>>;
  set(key: string, value: string, mode: "EX", seconds: number): Promise<unknown>;
  del(key: string): Promise<unknown>;
  ping(): Promise<string>;
  disconnect(): Promise<void>;
}

export class RedisRelayHub implements RelayMessageBus {
  private readonly listeners = new Map<string, Set<(message: string) => void>>();

  constructor(
    private readonly publisher: Redis,
    private readonly subscriber: Redis
  ) {
    this.subscriber.on("message", (channel, message) => {
      const channelListeners = this.listeners.get(channel);
      if (!channelListeners) return;
      for (const listener of channelListeners) {
        listener(message);
      }
    });
  }

  async publish(channel: string, message: string): Promise<number> {
    return this.publisher.publish(channel, message);
  }

  async subscribe(channel: string, listener: (message: string) => void): Promise<() => Promise<void>> {
    let channelListeners = this.listeners.get(channel);
    if (!channelListeners) {
      channelListeners = new Set();
      this.listeners.set(channel, channelListeners);
      await this.subscriber.subscribe(channel);
    }
    channelListeners.add(listener);

    return async () => {
      const listeners = this.listeners.get(channel);
      if (!listeners) return;
      listeners.delete(listener);
      if (listeners.size === 0) {
        this.listeners.delete(channel);
        await this.subscriber.unsubscribe(channel);
      }
    };
  }

  async set(key: string, value: string, mode: "EX", seconds: number): Promise<unknown> {
    return this.publisher.set(key, value, mode, seconds);
  }

  async del(key: string): Promise<unknown> {
    return this.publisher.del(key);
  }

  async ping(): Promise<string> {
    return this.publisher.ping();
  }

  async disconnect(): Promise<void> {
    await Promise.allSettled([
      this.subscriber.quit(),
      this.publisher.quit(),
    ]);
  }
}
