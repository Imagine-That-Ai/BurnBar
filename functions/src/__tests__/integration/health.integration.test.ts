/**
 * Integration tests for Firebase Cloud Functions health endpoints.
 * These tests hit the Firebase Functions Emulator (must be running).
 * Start emulator: npm run serve
 * Run: FUNCTIONS_EMULATOR=true vitest run --testPathPattern=integration
 */
import { describe, it, expect } from 'vitest';

const EMULATOR_HOST = process.env.FUNCTIONS_EMULATOR_HOST ?? 'localhost:5001';
const PROJECT_ID = process.env.FIREBASE_PROJECT_ID ?? 'openburnbar-dev';
const BASE_URL = `http://${EMULATOR_HOST}/${PROJECT_ID}/us-central1`;

// Skip integration tests unless emulator is explicitly enabled
const describeIf = (condition: boolean) => condition ? describe : describe.skip;
const EMULATOR_ENABLED = process.env.FUNCTIONS_EMULATOR === 'true';

describeIf(EMULATOR_ENABLED)('Health Endpoint Integration Tests', () => {
  describe('GET /healthLive', () => {
    it('returns 200 with alive status', async () => {
      const res = await fetch(`${BASE_URL}/healthLive`);
      expect(res.status).toBe(200);
      const body = await res.json() as { status: string };
      expect(body.status).toBe('alive');
    });

    it('responds within 500ms', async () => {
      const start = Date.now();
      await fetch(`${BASE_URL}/healthLive`);
      expect(Date.now() - start).toBeLessThan(500);
    });
  });

  describe('GET /healthReady', () => {
    it('returns 200 or 503 with JSON body', async () => {
      const res = await fetch(`${BASE_URL}/healthReady`);
      expect([200, 503]).toContain(res.status);
      const body = await res.json() as { status: string };
      expect(body.status).toBeDefined();
    });
  });

  describe('GET /healthCheck', () => {
    it('returns 200 with full status object', async () => {
      const res = await fetch(`${BASE_URL}/healthCheck`);
      expect(res.status).toBe(200);
      const body = await res.json() as Record<string, unknown>;
      expect(body.status).toBe('ok');
      expect(body.timestamp).toBeDefined();
      expect(body.uptime_ms).toBeDefined();
    });
  });
});
