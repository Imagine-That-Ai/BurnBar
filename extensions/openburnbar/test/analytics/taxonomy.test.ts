import { describe, expect, it } from 'vitest';

import { EVENT, COMMAND_ID, SURFACE, OUTCOME, eventCategory } from '../../src/analytics/events';

const ALL_EVENTS = Object.values(EVENT);

/**
 * Governance gates ported from docs/analytics/event-taxonomy.md § Governance.
 * These are the same rules the macOS unit tests enforce — names byte-identical,
 * casing strict, categories valid, and no PII-shaped tokens in any literal.
 */
describe('event taxonomy governance', () => {
  it('every event name matches the canonical scheme ^[a-z0-9]+(\\.[a-z0-9_]+)+$', () => {
    const NAME = /^[a-z0-9]+(\.[a-z0-9_]+)+$/;
    for (const name of ALL_EVENTS) {
      expect(name, `event "${name}" violates the naming scheme`).toMatch(NAME);
    }
  });

  it('Tier 1 shared names are reused VERBATIM from the cross-platform spine', () => {
    // These must be byte-identical to AnalyticsEvent.swift / website events.ts.
    expect(EVENT.appSessionStarted).toBe('app.session.started');
    expect(EVENT.appOpened).toBe('app.opened');
    expect(EVENT.appSessionEnded).toBe('app.session.ended');
    expect(EVENT.screenViewed).toBe('screen.viewed');
    expect(EVENT.settingsChanged).toBe('settings.changed');
    expect(EVENT.errorHandled).toBe('error.handled');
    expect(EVENT.consentAnalyticsGranted).toBe('consent.analytics.granted');
  });

  it('Tier 2 names follow surface.object.action under the vscode surface', () => {
    expect(EVENT.vscodeExtensionActivated).toBe('vscode.extension.activated');
    expect(EVENT.vscodeCommandInvoked).toBe('vscode.command.invoked');
    expect(EVENT.vscodePanelAction).toBe('vscode.panel.action');
    expect(EVENT.vscodeRunAction).toBe('vscode.run.action');
    expect(EVENT.vscodeDaemonConnection).toBe('vscode.daemon.connection');
  });

  it('every event maps to exactly one valid category', () => {
    const VALID = new Set(['lifecycle', 'screen_view', 'primary_action', 'conversion_auth', 'error']);
    for (const name of ALL_EVENTS) {
      const cat = eventCategory(name);
      expect(VALID.has(cat), `"${name}" → "${cat}" is not a valid category`).toBe(true);
    }
  });

  it('categories are assigned correctly for the spine', () => {
    expect(eventCategory(EVENT.appSessionStarted)).toBe('lifecycle');
    expect(eventCategory(EVENT.appOpened)).toBe('lifecycle');
    expect(eventCategory(EVENT.consentAnalyticsGranted)).toBe('lifecycle');
    expect(eventCategory(EVENT.vscodeExtensionActivated)).toBe('lifecycle');
    expect(eventCategory(EVENT.vscodeDaemonConnection)).toBe('lifecycle');
    expect(eventCategory(EVENT.screenViewed)).toBe('screen_view');
    expect(eventCategory(EVENT.errorHandled)).toBe('error');
    expect(eventCategory(EVENT.vscodeCommandInvoked)).toBe('primary_action');
    expect(eventCategory(EVENT.vscodeRunAction)).toBe('primary_action');
    expect(eventCategory(EVENT.settingsChanged)).toBe('primary_action');
  });

  it('event names are unique (no accidental duplicate wire names)', () => {
    expect(new Set(ALL_EVENTS).size).toBe(ALL_EVENTS.length);
  });

  it('this platform sets NO user_id: there is no conversion_auth event', () => {
    // The extension has no sign-in flow, so identity is anonymous device_id only.
    for (const name of ALL_EVENTS) {
      expect(eventCategory(name)).not.toBe('conversion_auth');
    }
  });
});

/**
 * Registry-vs-canon governance gate. The prior describe block proves each name is
 * well-FORMED; this one proves each name is REGISTERED — i.e. actually present in
 * the canonical taxonomy doc (docs/analytics/event-taxonomy.md). Wire names appear
 * there as inline-code `surface.object.action` tokens; we harvest every
 * backtick-wrapped dotted token and assert this platform's entire EVENT registry
 * is a subset. An event renamed in code but not in the doc (or invented locally)
 * is off-taxonomy and fails here — the doc is the source of truth, so the doc must
 * be updated FIRST.
 */
describe('every registered wire name is in the canonical taxonomy doc', () => {
  /** Read the repo-root taxonomy doc and extract the set of registered wire names:
   *  backtick-wrapped `a.b[.c…]` tokens (lowercase/digits/underscore segments).
   *  This matches event names like `vscode.command.invoked`; camelCase API
   *  references (e.g. `vscode.env.isTelemetryEnabled`) are naturally excluded
   *  because an uppercase letter breaks the `[a-z0-9_]` segment class. */
  async function registeredWireNames(): Promise<Set<string>> {
    const { readFileSync } = await import('node:fs');
    const { join, dirname } = await import('node:path');
    const { fileURLToPath } = await import('node:url');

    const here = dirname(fileURLToPath(import.meta.url)); // …/test/analytics
    const docPath = join(here, '..', '..', '..', '..', 'docs', 'analytics', 'event-taxonomy.md');
    const doc = readFileSync(docPath, 'utf8');

    const TOKEN = /`([a-z0-9]+(?:\.[a-z0-9_]+)+)`/g;
    const names = new Set<string>();
    for (const match of doc.matchAll(TOKEN)) names.add(match[1]);
    return names;
  }

  it('the doc actually parses into a non-trivial set of dotted tokens', async () => {
    const registered = await registeredWireNames();
    // Guard against a path/parse regression silently producing an empty set
    // (which would make the membership assertion vacuously pass).
    expect(registered.size).toBeGreaterThan(10);
  });

  it('EVERY name in this platform’s EVENT registry is registered in the doc', async () => {
    const registered = await registeredWireNames();
    for (const name of ALL_EVENTS) {
      expect(registered.has(name), `event "${name}" is NOT registered in docs/analytics/event-taxonomy.md`).toBe(true);
    }
  });

  it('an off-taxonomy name is rejected (negative control)', async () => {
    const registered = await registeredWireNames();
    // A plausibly-shaped but unregistered name must NOT be a member — proving the
    // gate has teeth and would fail if a real event drifted off-taxonomy.
    expect(registered.has('vscode.command.invoked')).toBe(true); // sanity: a real one IS present
    expect(registered.has('vscode.totally.madeup_action')).toBe(false);
  });
});

describe('bounded property-value enums', () => {
  const ENUM_VALUE = /^[a-z0-9]+(_[a-z0-9]+)*$/;

  it('command ids are bounded snake_case literals (never args/paths/text)', () => {
    for (const id of Object.values(COMMAND_ID)) {
      expect(id, `command id "${id}"`).toMatch(ENUM_VALUE);
    }
    // The private workspace-RPC channel is intentionally NOT trackable.
    expect(Object.values(COMMAND_ID)).not.toContain('private');
    expect(Object.values(COMMAND_ID)).not.toContain('workspace.rpc');
  });

  it('surface + outcome enums are bounded snake_case literals', () => {
    for (const s of Object.values(SURFACE)) expect(s).toMatch(ENUM_VALUE);
    for (const o of Object.values(OUTCOME)) expect(o).toMatch(ENUM_VALUE);
  });
});

/**
 * Static PII / raw-number sweep over the analytics module's own source. The TYPE
 * system already forbids raw numeric property values (AnalyticsProps is
 * Record<string, string|boolean>), and the transport disables fingerprinting —
 * this is a belt-and-suspenders grep that fails CI if a banned token ever shows
 * up at a literal call site.
 */
describe('PII / raw-number static sweep of the analytics module', () => {
  it('no banned identifiers appear as property keys in instrumentation source', async () => {
    const { readFileSync, readdirSync } = await import('node:fs');
    const { join, dirname } = await import('node:path');
    const { fileURLToPath } = await import('node:url');

    const analyticsDir = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src', 'analytics');
    const files = readdirSync(analyticsDir).filter((f) => f.endsWith('.ts'));

    // Keys that must never be a property name on any event payload.
    const BANNED_PROP_KEYS = [
      'email',
      'prompt',
      'message_body',
      'file_path',
      'api_key',
      'secret',
      'token',
      'password',
      'run_id',
      'uuid',
      'user_text',
      'content'
    ];

    for (const file of files) {
      const text = readFileSync(join(analyticsDir, file), 'utf8');
      for (const banned of BANNED_PROP_KEYS) {
        // `api_key` is the mandatory Amplitude HTTP V2 *envelope* field that the
        // transport puts on the request body (our own key, sent over TLS to
        // Amplitude) — it is NEVER an event-property key. Allow it there and only
        // there; ban it (and every other listed key) in every other file.
        if (banned === 'api_key' && file === 'amplitudeTransport.ts') continue;
        // Match an object-literal key like `prompt:` or `'file_path':` — not the
        // word inside a comment/string explaining what we DON'T send.
        const asKey = new RegExp(`['"\`]?\\b${banned}\\b['"\`]?\\s*:`, 'g');
        const hits = text.match(asKey) ?? [];
        expect(hits.length, `${file} uses banned property key "${banned}:"`).toBe(0);
      }
    }
  });
});
