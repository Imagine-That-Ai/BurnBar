export interface BrowserEvent<TListener extends (...args: never[]) => unknown> {
  addListener(listener: TListener): void;
  removeListener?(listener: TListener): void;
}

export interface BrowserTab {
  id?: number;
  windowId?: number;
  active?: boolean;
  currentWindow?: boolean;
  url?: string;
  title?: string;
  favIconUrl?: string;
  status?: string;
}

export interface BrowserRuntimeMessageSender {
  tab?: BrowserTab;
  frameId?: number;
  id?: string;
  url?: string;
}

export type RuntimeMessageListener = (
  message: unknown,
  sender: BrowserRuntimeMessageSender
) => unknown | Promise<unknown>;

export interface BrowserAPI {
  runtime: {
    id?: string;
    getURL(path: string): string;
    getManifest(): { version: string };
    sendMessage(message: unknown): Promise<unknown>;
    sendNativeMessage(application: string, message: unknown): Promise<unknown>;
    onMessage: BrowserEvent<RuntimeMessageListener>;
    onInstalled?: BrowserEvent<() => void>;
    onStartup?: BrowserEvent<() => void>;
  };
  tabs: {
    query(query: Record<string, unknown>): Promise<BrowserTab[]>;
    get(tabId: number): Promise<BrowserTab>;
    sendMessage(tabId: number, message: unknown): Promise<unknown>;
    captureVisibleTab(windowId?: number, options?: Record<string, unknown>): Promise<string>;
    create(options: Record<string, unknown>): Promise<BrowserTab>;
    update(tabId: number, options: Record<string, unknown>): Promise<BrowserTab>;
    remove(tabId: number): Promise<void>;
    reload(tabId: number): Promise<void>;
    goBack?(tabId: number): Promise<void>;
    goForward?(tabId: number): Promise<void>;
    onRemoved?: BrowserEvent<(tabId: number) => void>;
    onUpdated?: BrowserEvent<(tabId: number, changeInfo: Record<string, unknown>, tab: BrowserTab) => void>;
    onActivated?: BrowserEvent<(activeInfo: { tabId: number; windowId: number }) => void>;
  };
  scripting: {
    executeScript(options: {
      target: { tabId: number; allFrames?: boolean };
      files?: string[];
      func?: (...args: unknown[]) => unknown;
      args?: unknown[];
    }): Promise<Array<{ result?: unknown }>>;
  };
  permissions: {
    contains(permissions: { origins?: string[]; permissions?: string[] }): Promise<boolean>;
    request(permissions: { origins?: string[]; permissions?: string[] }): Promise<boolean>;
    remove(permissions: { origins?: string[]; permissions?: string[] }): Promise<boolean>;
  };
  storage: {
    local: {
      get(keys?: string | string[] | Record<string, unknown> | null): Promise<Record<string, unknown>>;
      set(items: Record<string, unknown>): Promise<void>;
      remove(keys: string | string[]): Promise<void>;
    };
  };
  alarms?: {
    create(name: string, alarmInfo: { delayInMinutes?: number; periodInMinutes?: number }): Promise<void> | void;
    onAlarm: BrowserEvent<(alarm: { name: string }) => void>;
  };
}

export function getBrowserAPI(candidate?: unknown): BrowserAPI {
  const resolved =
    candidate ??
    (
      globalThis as unknown as {
        browser?: unknown;
      }
    ).browser;
  if (!resolved || typeof resolved !== 'object') {
    throw new Error('The WebExtension browser API is unavailable.');
  }
  return resolved as BrowserAPI;
}

export async function activeTab(browserAPI: BrowserAPI): Promise<BrowserTab | undefined> {
  const tabs = await browserAPI.tabs.query({ active: true, currentWindow: true });
  return tabs[0];
}
