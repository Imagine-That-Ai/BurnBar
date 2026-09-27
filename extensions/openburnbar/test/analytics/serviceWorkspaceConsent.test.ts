import { beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

interface ConfigurationChangeEvent {
  affectsConfiguration(setting: string): boolean;
}

type ConfigurationListener = (event: ConfigurationChangeEvent) => void;

const vscodeState = vi.hoisted(() => {
  const state: {
    globalValue: boolean | undefined;
    workspaceValue: boolean | undefined;
    inspectAvailable: boolean;
    configurationListener: ConfigurationListener | undefined;
    showInformationMessage: ReturnType<typeof vi.fn>;
  } = {
    globalValue: undefined,
    workspaceValue: undefined,
    inspectAvailable: true,
    configurationListener: undefined,
    showInformationMessage: vi.fn()
  };
  return state;
});

function objectProperty(value: unknown, key: string): unknown {
  if (value === null || typeof value !== 'object') {
    return undefined;
  }
  return Object.getOwnPropertyDescriptor(value, key)?.value;
}

function analyticsConsentScopeFromManifest(): unknown {
  const here = dirname(fileURLToPath(import.meta.url));
  const manifestPath = join(here, '..', '..', 'package.json');
  const manifest: unknown = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const contributes = objectProperty(manifest, 'contributes');
  const configuration = objectProperty(contributes, 'configuration');
  const properties = objectProperty(configuration, 'properties');
  const analyticsSetting = objectProperty(properties, PROMPT_SETTING);
  return objectProperty(analyticsSetting, 'scope');
}

vi.mock(
  'vscode',
  () => ({
    ConfigurationTarget: {
      Global: 1
    },
    env: {
      appName: 'VS Code',
      isTelemetryEnabled: true
    },
    workspace: {
      getConfiguration: () => {
        const config = {
          get: (_key: string, fallback?: boolean) => vscodeState.workspaceValue ?? vscodeState.globalValue ?? fallback,
          update: async (_key: string, value: boolean) => {
            vscodeState.globalValue = value;
          },
          ...(vscodeState.inspectAvailable
            ? {
                inspect: (_key: string) => ({
                  globalValue: vscodeState.globalValue,
                  workspaceValue: vscodeState.workspaceValue
                })
              }
            : {})
        };
        return config;
      },
      onDidChangeConfiguration: (listener: ConfigurationListener) => {
        vscodeState.configurationListener = listener;
        return { dispose: () => undefined };
      }
    },
    window: {
      showInformationMessage: vscodeState.showInformationMessage
    }
  }),
  { virtual: true }
);

import { CONSENT_STORAGE_KEY } from '../../src/analytics/consent';
import {
  INSTALL_MARKER_KEY,
  OpenBurnBarAnalyticsService,
  resolveFirstActivation,
  type AnalyticsServiceHostContext
} from '../../src/analytics/service';

const PROMPT_SETTING = 'openburnbar.analytics.enabled';
const PROMPT_SEEN_KEY = 'openburnbar.analytics.promptSeen';
const DEVICE_ID_KEY = 'openburnbar.analytics.deviceId';

function createHostContext(initial: Record<string, unknown> = {}) {
  const storage = new Map<string, unknown>(Object.entries(initial));
  const context: AnalyticsServiceHostContext = {
    globalState: {
      get: (key: string) => storage.get(key),
      update: async (key: string, value: unknown) => {
        storage.set(key, value);
      }
    },
    subscriptions: [],
    extension: { packageJSON: { version: '9.9.9' } }
  };
  return { context, storage };
}

describe('OpenBurnBarAnalyticsService global opt-in boundary', () => {
  beforeEach(() => {
    vscodeState.globalValue = undefined;
    vscodeState.workspaceValue = undefined;
    vscodeState.inspectAvailable = true;
    vscodeState.configurationListener = undefined;
    vscodeState.showInformationMessage.mockReset();
  });

  it('ignores workspace analytics settings when syncing consent', () => {
    vscodeState.globalValue = false;
    vscodeState.workspaceValue = true;
    const { context, storage } = createHostContext();

    OpenBurnBarAnalyticsService.initialize(context);

    expect(storage.get(CONSENT_STORAGE_KEY)).toBeUndefined();
    expect(storage.get(PROMPT_SEEN_KEY)).toBeUndefined();
  });

  it('does not grant consent when only the workspace setting changes to enabled', () => {
    vscodeState.globalValue = false;
    vscodeState.workspaceValue = false;
    const { context, storage } = createHostContext();
    OpenBurnBarAnalyticsService.initialize(context);

    vscodeState.workspaceValue = true;
    vscodeState.configurationListener?.({
      affectsConfiguration: (setting) => setting === PROMPT_SETTING
    });

    expect(storage.get(CONSENT_STORAGE_KEY)).toBeUndefined();
  });

  it('mirrors only the global analytics setting into consent', () => {
    vscodeState.globalValue = true;
    vscodeState.workspaceValue = false;
    const { context, storage } = createHostContext();

    OpenBurnBarAnalyticsService.initialize(context);

    expect(storage.get(CONSENT_STORAGE_KEY)).toBe('granted');
    expect(storage.get(PROMPT_SEEN_KEY)).toBe(true);
  });

  it('fails closed when the host cannot inspect global configuration scope', () => {
    vscodeState.globalValue = false;
    vscodeState.workspaceValue = true;
    vscodeState.inspectAvailable = false;
    const { context, storage } = createHostContext();

    OpenBurnBarAnalyticsService.initialize(context);

    expect(storage.get(CONSENT_STORAGE_KEY)).toBeUndefined();
    expect(storage.get(PROMPT_SEEN_KEY)).toBeUndefined();
  });

  it('declares the analytics opt-in as user-scoped in the extension manifest', () => {
    expect(analyticsConsentScopeFromManifest()).toBe('application');
  });
});

describe('OpenBurnBarAnalyticsService first activation', () => {
  beforeEach(() => {
    vscodeState.globalValue = undefined;
    vscodeState.workspaceValue = undefined;
    vscodeState.inspectAvailable = true;
    vscodeState.configurationListener = undefined;
    vscodeState.showInformationMessage.mockReset();
  });

  it('treats an empty install as first activation and writes the marker', () => {
    const { context, storage } = createHostContext();
    expect(resolveFirstActivation(context)).toBe(true);

    OpenBurnBarAnalyticsService.initialize(context);

    expect(storage.get(INSTALL_MARKER_KEY)).toBe(true);
    expect(resolveFirstActivation(context)).toBe(false);
  });

  it('does not treat a newly minted device id as prior-install evidence', () => {
    const { context, storage } = createHostContext();
    expect(storage.get(DEVICE_ID_KEY)).toBeUndefined();
    expect(resolveFirstActivation(context)).toBe(true);

    OpenBurnBarAnalyticsService.initialize(context);

    expect(typeof storage.get(DEVICE_ID_KEY)).toBe('string');
    expect(String(storage.get(DEVICE_ID_KEY)).length).toBeGreaterThan(0);
    // This process already captured first-activation=true; later activations
    // use the dedicated marker, not the device id minted during this boot.
    expect(storage.get(INSTALL_MARKER_KEY)).toBe(true);
  });

  it('is not a first activation when the analytics prompt was already handled', () => {
    const { context } = createHostContext({ [PROMPT_SEEN_KEY]: true });
    expect(resolveFirstActivation(context)).toBe(false);
    OpenBurnBarAnalyticsService.initialize(context);
    expect(resolveFirstActivation(context)).toBe(false);
  });

  it('is not a first activation when a prior device id already exists', () => {
    const { context } = createHostContext({ [DEVICE_ID_KEY]: 'already-installed-uuid' });
    expect(resolveFirstActivation(context)).toBe(false);
  });

  it('is not a first activation when consent was already granted or declined', () => {
    expect(
      resolveFirstActivation(createHostContext({ [CONSENT_STORAGE_KEY]: 'granted' }).context)
    ).toBe(false);
    expect(
      resolveFirstActivation(createHostContext({ [CONSENT_STORAGE_KEY]: 'declined' }).context)
    ).toBe(false);
  });

  it('is still a first activation when only the synced global opt-in is present', () => {
    vscodeState.globalValue = true;
    const { context, storage } = createHostContext();
    expect(resolveFirstActivation(context)).toBe(true);
    OpenBurnBarAnalyticsService.initialize(context);
    expect(storage.get(INSTALL_MARKER_KEY)).toBe(true);
  });
});
