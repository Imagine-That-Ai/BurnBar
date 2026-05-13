import { Redis, type RedisOptions } from "ioredis";
import type { RelayConfig } from "./config.js";
import { logError } from "./logging.js";

type RedisClientConfig = Pick<RelayConfig, "redisURL" | "redisTLSCA" | "redisTLSServername">;

export function redisOptionsForConfig(config: RedisClientConfig): RedisOptions {
  const url = new URL(config.redisURL);
  const tlsEnabled =
    url.protocol === "rediss:" ||
    config.redisTLSCA !== undefined ||
    config.redisTLSServername !== undefined;
  const options: RedisOptions = {
    enableReadyCheck: true,
    maxRetriesPerRequest: 3,
    lazyConnect: false,
    connectTimeout: 10_000,
    commandTimeout: 30_000,
  };
  if (tlsEnabled) {
    options.tls = {
      minVersion: "TLSv1.2",
      ...(config.redisTLSCA ? { ca: config.redisTLSCA } : {}),
      ...(config.redisTLSServername ? { servername: config.redisTLSServername } : {}),
    };
  }
  return options;
}

export function createRedisClient(config: RedisClientConfig, role: string): Redis {
  const client = new Redis(config.redisURL, redisOptionsForConfig(config));
  client.on("error", (error) => {
    logError("redis_error", error, { role });
  });
  return client;
}
