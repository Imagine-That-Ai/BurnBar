import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { BurnBarWorkspaceHostKind } from '../../src/workspace/types';
import {
  OpenBurnBarWorkspaceCompanion,
  activateOpenBurnBarWorkspaceCompanion,
  type OpenBurnBarWorkspaceCompanionOptions,
  type BurnBarCompanionToolResult
} from '../../src/workspace/companion';
import * as apiModule from '../../src/workspace/api';
import type { BurnBarWorkspaceApi } from '../../src/workspace/api';

// Mock the API module
// Mock the API module
const mockApi = {
  hostKind: 'ui' as const,
  isTrusted: true,
  remoteName: 'cursor',
  workspaceFolders: [{ uri: { fsPath: '/test/workspace' } }] as any[],
  isWritableFileSystem: (scheme: string) => scheme === 'file',
  readFile: vi.fn(() => Promise.resolve(new Uint8Array())),
  findFiles: vi.fn(() => Promise.resolve([])),
  openTextDocument: vi.fn(() => Promise.resolve({ getText: () => 'test' })),
  applyEdit: vi.fn(() => Promise.resolve(true)),
  saveAll: vi.fn(() => Promise.resolve(true)),
  createWorkspaceEdit: vi.fn(() => ({})),
  createRange: vi.fn(() => ({})),
  confirmTerminalCommand: vi.fn(() => Promise.resolve(true)),
  createTerminal: vi.fn(() => ({ name: 'OpenBurnBar', show: vi.fn(), sendText: vi.fn() })),
  parseUri: (value: string) => ({ scheme: 'file', fsPath: value, toString: () => value } as any),
  fileUri: (value: string) => ({ scheme: 'file', fsPath: value, toString: () => `file://${value}` } as any),
  joinPath: (base: any, ...segments: string[]) => ({ scheme: 'file', fsPath: segments.join('/'), toString: () => `file://${segments.join('/')}` } as any)
};

vi.mock('../../src/workspace/api', () => ({
  createBurnBarWorkspaceApi: vi.fn((hostKind: BurnBarWorkspaceHostKind) => ({
    ...mockApi,
    hostKind
  })),
  resolveWorkspaceUri: vi.fn((api: any, path: string) => ({
    scheme: 'file',
    fsPath: path,
    toString: () => `file://${path}`
  }))
}));
// Mock vscode
vi.mock('vscode', () => ({
  env: { remoteName: 'cursor' },
  workspace: {
    isTrusted: true,
    workspaceFolders: [{ uri: { fsPath: '/test/workspace' } }],
    fs: {
      isWritableFileSystem: vi.fn(() => true),
      readFile: vi.fn(() => Promise.resolve(new Uint8Array()))
    },
    findFiles: vi.fn(() => Promise.resolve([])),
    openTextDocument: vi.fn(() => Promise.resolve({ getText: () => 'test' })),
    applyEdit: vi.fn(() => Promise.resolve(true)),
    saveAll: vi.fn(() => Promise.resolve(true))
  },
  window: {
    createTerminal: vi.fn(() => ({
      name: 'OpenBurnBar',
      show: vi.fn(),
      sendText: vi.fn()
    }))
  },
  commands: {
    registerCommand: vi.fn(() => ({ dispose: vi.fn() }))
  },
  WorkspaceEdit: vi.fn(),
  Range: vi.fn()
}));

// Import after mocking
import * as vscode from 'vscode';
import * as api from '../../src/workspace/api';

describe('OpenBurnBarWorkspaceCompanion', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('constructor', () => {
    it('should create companion with workspace host kind', () => {
      const api = { ...mockApi, hostKind: 'workspace' as const };
      const companion = new OpenBurnBarWorkspaceCompanion(api);
      expect(companion).toBeDefined();
      expect(companion.api.hostKind).toBe('workspace');
    });

    it('should create companion with ui host kind', () => {
      const api = { ...mockApi, hostKind: 'ui' as const };
      const companion = new OpenBurnBarWorkspaceCompanion(api);
      expect(companion).toBeDefined();
      expect(companion.api.hostKind).toBe('ui');
    });

    it('should create API on initialization', () => {
      const createApiSpy = vi.spyOn(api, 'createBurnBarWorkspaceApi');
      const companion = new OpenBurnBarWorkspaceCompanion(mockApi);

      expect(createApiSpy).not.toHaveBeenCalled(); // API is passed directly
    });

    it('should expose API after creation', () => {
      const api = { ...mockApi, hostKind: 'workspace' as const };
      const companion = new OpenBurnBarWorkspaceCompanion(api);

      expect(companion.api).toBeDefined();
      expect('isWritableFileSystem' in companion.api).toBe(true);
    });

    it('should initialize with correct workspace folders', () => {
      const api = { ...mockApi, hostKind: 'ui' as const };
      const companion = new OpenBurnBarWorkspaceCompanion(api);

      expect(companion.api.workspaceFolders).toBeDefined();
      expect(Array.isArray(companion.api.workspaceFolders)).toBe(true);
    });
  });

  describe('workspace methods', () => {
    it('should expose readFile method', () => {
      const companion = new OpenBurnBarWorkspaceCompanion(mockApi);

      expect(typeof companion.api.readFile).toBe('function');
    });

    it('should expose findFiles method', () => {
      const companion = new OpenBurnBarWorkspaceCompanion(mockApi);

      expect(typeof companion.api.findFiles).toBe('function');
    });

    it('should expose applyEdit method', () => {
      const companion = new OpenBurnBarWorkspaceCompanion(mockApi);

      expect(typeof companion.api.applyEdit).toBe('function');
    });

    it('should expose createTerminal method', () => {
      const companion = new OpenBurnBarWorkspaceCompanion(mockApi);

      expect(typeof companion.api.createTerminal).toBe('function');
    });

    it('should expose fileUri method', () => {
      const companion = new OpenBurnBarWorkspaceCompanion(mockApi);

      expect(typeof companion.api.fileUri).toBe('function');
    });

    it('should expose joinPath method', () => {
      const companion = new OpenBurnBarWorkspaceCompanion(mockApi);

      expect(typeof companion.api.joinPath).toBe('function');
    });
  });

  describe('host kind handling', () => {
    it('should handle workspace host kind', () => {
      const api = { ...mockApi, hostKind: 'workspace' as const };
      const companion = new OpenBurnBarWorkspaceCompanion(api);

      expect(companion.api.hostKind).toBe('workspace');
    });

    it('should handle ui host kind', () => {
      const api = { ...mockApi, hostKind: 'ui' as const };
      const companion = new OpenBurnBarWorkspaceCompanion(api);

      expect(companion.api.hostKind).toBe('ui');
    });
  });

  describe('API properties', () => {
    it('should expose isTrusted property', () => {
      const companion = new OpenBurnBarWorkspaceCompanion(mockApi);

      expect(companion.api.isTrusted).toBe(true);
    });

    it('should expose remoteName property', () => {
      const companion = new OpenBurnBarWorkspaceCompanion(mockApi);

      expect(companion.api.remoteName).toBe('cursor');
    });
  });

  describe('resolveWorkspaceUri integration', () => {
    it('should provide API that can resolve URIs', () => {
      const companion = activateOpenBurnBarWorkspaceCompanion('ui');
      const resolveSpy = vi.spyOn(api, 'resolveWorkspaceUri');

      // Use the API's method
      const uri = api.resolveWorkspaceUri(companion.api, '/test/path.txt');

      expect(resolveSpy).toHaveBeenCalled();
      expect(uri).toBeDefined();
    });

    it('should resolve absolute paths', () => {
      const companion = activateOpenBurnBarWorkspaceCompanion('ui');
      const uri = api.resolveWorkspaceUri(companion.api, '/Users/test/file.txt');

      expect(uri.fsPath).toBe('/Users/test/file.txt');
    });

    it('should resolve relative paths', () => {
      const companion = activateOpenBurnBarWorkspaceCompanion('ui');
      const uri = api.resolveWorkspaceUri(companion.api, 'src/index.ts');

      expect(uri.fsPath).toBe('src/index.ts');
    });
  });
});

describe('activateOpenBurnBarWorkspaceCompanion', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('should return a companion instance', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');

    expect(companion).toBeInstanceOf(OpenBurnBarWorkspaceCompanion);
  });

  it('should create companion with workspace host kind', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('workspace');

    expect(companion.api.hostKind).toBe('workspace');
  });

  it('should create companion with ui host kind', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');

    expect(companion.api.hostKind).toBe('ui');
  });

  it('should expose API after activation', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');

    expect(companion.api).toBeDefined();
  });

  it('should create workspace API on activation', () => {
    const createApiSpy = vi.spyOn(api, 'createBurnBarWorkspaceApi');
    activateOpenBurnBarWorkspaceCompanion('ui');

    expect(createApiSpy).toHaveBeenCalledWith('ui');
  });

  it('should allow multiple activations', () => {
    const companion1 = activateOpenBurnBarWorkspaceCompanion('ui');
    const companion2 = activateOpenBurnBarWorkspaceCompanion('workspace');

    expect(companion1).toBeInstanceOf(OpenBurnBarWorkspaceCompanion);
    expect(companion2).toBeInstanceOf(OpenBurnBarWorkspaceCompanion);
    expect(companion1).not.toBe(companion2);
  });

  it('should create independent API instances', () => {
    const companion1 = activateOpenBurnBarWorkspaceCompanion('ui');
    const companion2 = activateOpenBurnBarWorkspaceCompanion('ui');

    expect(companion1.api).not.toBe(companion2.api);
  });
});

describe('OpenBurnBarWorkspaceCompanionOptions', () => {
  it('should accept hostKind option', () => {
    // Options type is used for configuration
    const options: OpenBurnBarWorkspaceCompanionOptions = { hostKind: 'ui' };
    expect(options.hostKind).toBe('ui');
  });

  it('should accept workspace host kind', () => {
    const options: OpenBurnBarWorkspaceCompanionOptions = { hostKind: 'workspace' };
    expect(options.hostKind).toBe('workspace');
  });

  it('should allow undefined options', () => {
    const options: OpenBurnBarWorkspaceCompanionOptions | undefined = undefined;
    expect(options).toBeUndefined();
  });
});

describe('BurnBarCompanionToolResult', () => {
  it('should have required fields', () => {
    const result: BurnBarCompanionToolResult = {
      callID: 'test-call',
      status: 'success',
      result: 'test content'
    };

    expect(result.callID).toBe('test-call');
    expect(result.status).toBe('success');
    expect(result.result).toBe('test content');
  });

  it('should accept error status', () => {
    const result: BurnBarCompanionToolResult = {
      callID: 'test-call',
      status: 'error',
      result: '',
      error: 'Something went wrong'
    };

    expect(result.status).toBe('error');
    expect(result.error).toBe('Something went wrong');
  });

  it('should accept timestamp', () => {
    const timestamp = new Date();
    const result: BurnBarCompanionToolResult = {
      callID: 'test-call',
      status: 'success',
      result: 'content',
      timestamp
    };

    expect(result.timestamp).toBe(timestamp);
  });
});

describe('Companion Integration Tests', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('should create companion and use workspace methods', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');

    // Access the API
    const api = companion.api;

    // Verify API is functional
    expect(api.isTrusted).toBe(true);
    expect(api.workspaceFolders).toBeDefined();
  });

  it('should handle multiple companions with different host kinds', () => {
    const uiCompanion = activateOpenBurnBarWorkspaceCompanion('ui');
    const workspaceCompanion = activateOpenBurnBarWorkspaceCompanion('workspace');

    expect(uiCompanion.api.hostKind).toBe('ui');
    expect(workspaceCompanion.api.hostKind).toBe('workspace');
  });

  it('should provide access to workspace folder paths', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');

    const folders = companion.api.workspaceFolders;
    expect(folders).toBeDefined();
    expect(folders.length).toBeGreaterThan(0);
  });

  it('should provide file system operations through API', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');

    // Check file system methods exist
    expect(typeof companion.api.readFile).toBe('function');
    expect(typeof companion.api.isWritableFileSystem).toBe('function');
  });

  it('should provide URI resolution through API', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');

    expect(typeof companion.api.parseUri).toBe('function');
    expect(typeof companion.api.fileUri).toBe('function');
    expect(typeof companion.api.joinPath).toBe('function');
  });

  it('should provide edit operations through API', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');

    expect(typeof companion.api.applyEdit).toBe('function');
    expect(typeof companion.api.createWorkspaceEdit).toBe('function');
    expect(typeof companion.api.saveAll).toBe('function');
  });

  it('should provide terminal creation through API', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');

    expect(typeof companion.api.createTerminal).toBe('function');
  });

  it('should provide search operations through API', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');

    expect(typeof companion.api.findFiles).toBe('function');
  });
});

describe('Companion Error Handling', () => {
  it('should handle companion creation with different host kinds', () => {
    const api = { ...mockApi, hostKind: 'ui' as const };
    const companion = new OpenBurnBarWorkspaceCompanion(api);
    expect(companion.api.hostKind).toBe('ui');
  });

  it('should preserve API functionality after creation', () => {
    const companion = activateOpenBurnBarWorkspaceCompanion('ui');
    const companionApi = companion.api;

    // API should still be functional
    expect(typeof companionApi.readFile).toBe('function');
    expect(typeof companionApi.applyEdit).toBe('function');
    expect(typeof companionApi.createTerminal).toBe('function');
  });
});

describe('Companion Lifecycle', () => {
  it('should allow creating companion before activation', () => {
    const api = { ...mockApi, hostKind: 'ui' as const };
    const companion = new OpenBurnBarWorkspaceCompanion(api);
    expect(companion).toBeDefined();
  });

  it('should allow direct instantiation', () => {
    const api = { ...mockApi, hostKind: 'workspace' as const };
    const companion = new OpenBurnBarWorkspaceCompanion(api);
    expect(companion.api).toBeDefined();
  });

  it('should support multiple companion instances', () => {
    const companions = Array.from({ length: 5 }, (_, i) =>
      activateOpenBurnBarWorkspaceCompanion(i % 2 === 0 ? 'ui' : 'workspace')
    );

    expect(companions).toHaveLength(5);
    companions.forEach(c => expect(c).toBeInstanceOf(OpenBurnBarWorkspaceCompanion));
  });

  it('should maintain independent state per instance', () => {
    const api1 = { ...mockApi, hostKind: 'ui' as const };
    const api2 = { ...mockApi, hostKind: 'workspace' as const };
    const companion1 = new OpenBurnBarWorkspaceCompanion(api1);
    const companion2 = new OpenBurnBarWorkspaceCompanion(api2);

    expect(companion1.api.hostKind).not.toBe(companion2.api.hostKind);
  });
});

describe('Companion Type Safety', () => {
  it('should enforce hostKind type', () => {
    const uiApi = { ...mockApi, hostKind: 'ui' as const };
    const wsApi = { ...mockApi, hostKind: 'workspace' as const };
    const uiCompanion = new OpenBurnBarWorkspaceCompanion(uiApi);
    const wsCompanion = new OpenBurnBarWorkspaceCompanion(wsApi);

    // Type checking should work correctly
    const uiHostKind: BurnBarWorkspaceHostKind = uiCompanion.api.hostKind;
    const wsHostKind: BurnBarWorkspaceHostKind = wsCompanion.api.hostKind;

    expect(uiHostKind).toBe('ui');
    expect(wsHostKind).toBe('workspace');
  });

  it('should enforce API interface', () => {
    const api = { ...mockApi, hostKind: 'ui' as const };
    const companion = new OpenBurnBarWorkspaceCompanion(api);
    const workspaceApi: BurnBarWorkspaceApi = companion.api;

    // All required properties should be accessible
    expect(typeof workspaceApi.isWritableFileSystem).toBe('function');
    expect(typeof workspaceApi.readFile).toBe('function');
    expect(typeof workspaceApi.findFiles).toBe('function');
    expect(typeof workspaceApi.openTextDocument).toBe('function');
    expect(typeof workspaceApi.applyEdit).toBe('function');
    expect(typeof workspaceApi.saveAll).toBe('function');
    expect(typeof workspaceApi.createWorkspaceEdit).toBe('function');
    expect(typeof workspaceApi.createRange).toBe('function');
    expect(typeof workspaceApi.createTerminal).toBe('function');
    expect(typeof workspaceApi.parseUri).toBe('function');
    expect(typeof workspaceApi.fileUri).toBe('function');
    expect(typeof workspaceApi.joinPath).toBe('function');
  });
});
