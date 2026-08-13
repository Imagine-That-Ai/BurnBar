import type {
  BrowserAPI,
  BrowserEvent,
  BrowserRuntimeMessageSender,
  BrowserTab,
  RuntimeMessageListener
} from '../../src/shared/browser';

class MockEvent<TListener extends (...args: never[]) => unknown> implements BrowserEvent<TListener> {
  readonly listeners: TListener[] = [];

  addListener(listener: TListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: TListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  emit(...args: Parameters<TListener>): void {
    for (const listener of [...this.listeners]) {
      listener(...args);
    }
  }
}

interface MockBrowserControls {
  runtimeMessage: MockEvent<RuntimeMessageListener>;
  installed: MockEvent<() => void>;
  startup: MockEvent<() => void>;
  tabRemoved: MockEvent<(tabId: number) => void>;
  tabUpdated: MockEvent<(tabId: number, changeInfo: Record<string, unknown>, tab: BrowserTab) => void>;
  tabActivated: MockEvent<(activeInfo: { tabId: number; windowId: number }) => void>;
  alarm: MockEvent<(alarm: { name: string }) => void>;
  tabs: Map<number, BrowserTab>;
  storage: Map<string, unknown>;
  grantedOrigins: Set<string>;
  nativeMessages: unknown[];
  runtimeMessages: unknown[];
  tabMessages: Array<{ tabId: number; message: unknown }>;
  scriptExecutions: unknown[];
  captures: string[];
  setStorageSetError(error: Error | undefined): void;
  setNativeHandler(handler: (message: unknown) => Promise<unknown> | unknown): void;
  setContentHandler(handler: (tabId: number, message: unknown) => Promise<unknown> | unknown): void;
  emitRuntimeMessage(message: unknown, sender?: BrowserRuntimeMessageSender): Promise<unknown>;
}

export function createMockBrowser(
  initialTabs: BrowserTab[] = [
    {
      id: 1,
      windowId: 10,
      active: true,
      currentWindow: true,
      url: 'https://example.com/',
      title: 'Example',
      status: 'complete'
    }
  ]
): { browser: BrowserAPI; controls: MockBrowserControls } {
  const runtimeMessage = new MockEvent<RuntimeMessageListener>();
  const installed = new MockEvent<() => void>();
  const startup = new MockEvent<() => void>();
  const tabRemoved = new MockEvent<(tabId: number) => void>();
  const tabUpdated = new MockEvent<(tabId: number, changeInfo: Record<string, unknown>, tab: BrowserTab) => void>();
  const tabActivated = new MockEvent<(activeInfo: { tabId: number; windowId: number }) => void>();
  const alarm = new MockEvent<(alarm: { name: string }) => void>();
  const tabs = new Map<number, BrowserTab>(
    initialTabs.flatMap((tab) => (typeof tab.id === 'number' ? [[tab.id, { ...tab }]] : []))
  );
  const storage = new Map<string, unknown>();
  const grantedOrigins = new Set<string>();
  const nativeMessages: unknown[] = [];
  const runtimeMessages: unknown[] = [];
  const tabMessages: Array<{ tabId: number; message: unknown }> = [];
  const scriptExecutions: unknown[] = [];
  const captures: string[] = ['data:image/jpeg;base64,anBlZw=='];
  let storageSetError: Error | undefined;
  let nativeHandler: (message: unknown) => Promise<unknown> | unknown = () => {
    throw new Error('Native handler not configured');
  };
  let contentHandler: (tabId: number, message: unknown) => Promise<unknown> | unknown = () => {
    throw new Error('Content handler not configured');
  };
  let nextTabId = Math.max(0, ...tabs.keys()) + 1;

  async function emitRuntimeMessage(message: unknown, sender: BrowserRuntimeMessageSender = {}): Promise<unknown> {
    for (const listener of [...runtimeMessage.listeners]) {
      const result = await listener(message, sender);
      if (result !== undefined) {
        return result;
      }
    }
    return undefined;
  }

  const browser: BrowserAPI = {
    runtime: {
      id: 'openburnbar-test',
      getURL: (path) => `safari-web-extension://openburnbar/${path}`,
      getManifest: () => ({ version: '1.0.34' }),
      sendMessage: async (message) => {
        runtimeMessages.push(message);
        return emitRuntimeMessage(message);
      },
      sendNativeMessage: async (_application, message) => {
        nativeMessages.push(message);
        return nativeHandler(message);
      },
      onMessage: runtimeMessage,
      onInstalled: installed,
      onStartup: startup
    },
    tabs: {
      query: async (query) => {
        let values = [...tabs.values()];
        if (query.active === true) {
          values = values.filter((tab) => tab.active);
        }
        if (query.currentWindow === true) {
          values = values.filter((tab) => tab.currentWindow !== false);
        }
        if (query.lastFocusedWindow === true) {
          values = values.filter((tab) => tab.currentWindow !== false);
        }
        return values.map((tab) => ({ ...tab }));
      },
      get: async (tabId) => {
        const tab = tabs.get(tabId);
        if (!tab) {
          throw new Error(`Missing tab ${tabId}`);
        }
        return { ...tab };
      },
      sendMessage: async (tabId, message) => {
        tabMessages.push({ tabId, message });
        return contentHandler(tabId, message);
      },
      captureVisibleTab: async () => captures.at(-1) ?? 'data:image/jpeg;base64,anBlZw==',
      create: async (options) => {
        for (const tab of tabs.values()) {
          tab.active = false;
        }
        const tabId = nextTabId;
        nextTabId += 1;
        const tab: BrowserTab = {
          id: tabId,
          windowId: 10,
          active: options.active !== false,
          currentWindow: true,
          url: typeof options.url === 'string' ? options.url : 'about:blank',
          title: '',
          status: 'complete'
        };
        tabs.set(tabId, tab);
        return { ...tab };
      },
      update: async (tabId, options) => {
        const tab = tabs.get(tabId);
        if (!tab) {
          throw new Error(`Missing tab ${tabId}`);
        }
        if (typeof options.url === 'string') {
          tab.url = options.url;
          tab.status = 'complete';
        }
        if (options.active === true) {
          for (const candidate of tabs.values()) {
            candidate.active = candidate.id === tabId;
          }
        }
        tabUpdated.emit(tabId, options, { ...tab });
        return { ...tab };
      },
      remove: async (tabId) => {
        tabs.delete(tabId);
        tabRemoved.emit(tabId);
      },
      reload: async (tabId) => {
        const tab = tabs.get(tabId);
        if (tab) {
          tabUpdated.emit(tabId, { status: 'loading' }, { ...tab });
          tabUpdated.emit(tabId, { status: 'complete' }, { ...tab });
        }
      },
      goBack: async () => undefined,
      goForward: async () => undefined,
      onRemoved: tabRemoved,
      onUpdated: tabUpdated,
      onActivated: tabActivated
    },
    scripting: {
      executeScript: async (options) => {
        scriptExecutions.push(options);
        return [{ result: true }];
      }
    },
    permissions: {
      contains: async (permissions) => (permissions.origins ?? []).every((origin) => grantedOrigins.has(origin)),
      request: async (permissions) => {
        for (const origin of permissions.origins ?? []) {
          grantedOrigins.add(origin);
        }
        return true;
      },
      remove: async (permissions) => {
        let removed = false;
        for (const origin of permissions.origins ?? []) {
          removed ||= grantedOrigins.delete(origin);
        }
        return removed;
      }
    },
    storage: {
      local: {
        get: async (keys) => {
          if (typeof keys === 'string') {
            return { [keys]: storage.get(keys) };
          }
          if (Array.isArray(keys)) {
            return Object.fromEntries(keys.map((key) => [key, storage.get(key)]));
          }
          if (keys && typeof keys === 'object') {
            return Object.fromEntries(
              Object.entries(keys).map(([key, fallback]) => [key, storage.get(key) ?? fallback])
            );
          }
          return Object.fromEntries(storage);
        },
        set: async (items) => {
          if (storageSetError) {
            throw storageSetError;
          }
          for (const [key, value] of Object.entries(items)) {
            storage.set(key, value);
          }
        },
        remove: async (keys) => {
          for (const key of typeof keys === 'string' ? [keys] : keys) {
            storage.delete(key);
          }
        }
      }
    },
    alarms: {
      create: () => undefined,
      onAlarm: alarm
    }
  };

  const controls: MockBrowserControls = {
    runtimeMessage,
    installed,
    startup,
    tabRemoved,
    tabUpdated,
    tabActivated,
    alarm,
    tabs,
    storage,
    grantedOrigins,
    nativeMessages,
    runtimeMessages,
    tabMessages,
    scriptExecutions,
    captures,
    setStorageSetError(error) {
      storageSetError = error;
    },
    setNativeHandler(handler) {
      nativeHandler = handler;
    },
    setContentHandler(handler) {
      contentHandler = handler;
    },
    emitRuntimeMessage
  };

  return { browser, controls };
}
