import * as path from 'node:path';

import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { BurnBarWorkspaceHostKind } from '../../src/workspace/types';
import {
  createBurnBarWorkspaceApi,
  resolveWorkspaceUri,
  type BurnBarWorkspaceApi,
  type BurnBarWorkspaceUri
} from '../../src/workspace/api';

// Mock vscode
vi.mock('vscode', () => ({
  Uri: {
    parse: (value: string) => {
      const scheme = value.split(':')[0] ?? 'file';
      const fsPath = scheme === 'file' ? value.replace(/^file:\/\//u, '') : value;
      return { scheme, fsPath, toString: () => value };
    },
    file: (value: string) => ({ scheme: 'file', fsPath: value, toString: () => `file://${value}` }),
    joinPath: (base: any, ...segments: string[]) => {
      const resolved = path.posix.resolve(base.fsPath, ...segments);
      return { scheme: 'file', fsPath: resolved, toString: () => `file://${resolved}` };
    }
  },
  env: {
    remoteName: 'cursor'
  },
  workspace: {
    isTrusted: true,
    workspaceFolders: [
      {
        uri: {
          scheme: 'file',
          fsPath: '/Users/test/project',
          toString: () => 'file:///Users/test/project'
        }
      }
    ],
    fs: {
      isWritableFileSystem: vi.fn(() => true),
      readFile: vi.fn(() => Promise.resolve(new Uint8Array()))
    },
    findFiles: vi.fn(() => Promise.resolve([])),
    openTextDocument: vi.fn(() => Promise.resolve({
      getText: () => 'test content'
    })),
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
  WorkspaceEdit: vi.fn(),
  Range: vi.fn()
}));

// Import vscode after mocking
import * as vscode from 'vscode';

const makeScopedWorkspaceApi = (): Pick<BurnBarWorkspaceApi, 'workspaceFolders' | 'parseUri' | 'fileUri' | 'joinPath'> => ({
  workspaceFolders: [
    {
      uri: {
        scheme: 'file',
        fsPath: '/Users/test/project',
        toString: () => 'file:///Users/test/project'
      }
    }
  ],
  parseUri: (value: string) => {
    const scheme = value.split(':')[0] ?? 'file';
    const fsPath = scheme === 'file' ? value.replace(/^file:\/\//u, '') : value;
    return { scheme, fsPath, toString: () => value };
  },
  fileUri: (value: string) => ({ scheme: 'file', fsPath: value, toString: () => `file://${value}` }),
  joinPath: (base: BurnBarWorkspaceUri, ...segments: string[]) => {
    const resolved = path.posix.resolve(base.fsPath, ...segments);
    return { scheme: base.scheme, fsPath: resolved, toString: () => `file://${resolved}` };
  }
});

describe('createBurnBarWorkspaceApi', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('should create API with ui host kind', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(api.hostKind).toBe('ui');
    expect(api.isTrusted).toBe(true);
  });

  it('should create API with workspace host kind', () => {
    const api = createBurnBarWorkspaceApi('workspace');

    expect(api.hostKind).toBe('workspace');
  });

  it('should expose workspace folders', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(api.workspaceFolders).toBeDefined();
    expect(Array.isArray(api.workspaceFolders)).toBe(true);
  });

  it('should expose remote name', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(api.remoteName).toBe('cursor');
  });

  it('should expose isWritableFileSystem method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.isWritableFileSystem).toBe('function');
    expect(api.isWritableFileSystem('file')).toBe(true);
  });

  it('should expose readFile method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.readFile).toBe('function');
  });

  it('should expose findFiles method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.findFiles).toBe('function');
  });

  it('should expose openTextDocument method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.openTextDocument).toBe('function');
  });

  it('should expose applyEdit method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.applyEdit).toBe('function');
  });

  it('should expose saveAll method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.saveAll).toBe('function');
  });

  it('should expose createWorkspaceEdit method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.createWorkspaceEdit).toBe('function');
  });

  it('should expose createRange method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.createRange).toBe('function');
  });

  it('should expose createTerminal method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.createTerminal).toBe('function');
  });

  it('should expose parseUri method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.parseUri).toBe('function');
  });

  it('should expose fileUri method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.fileUri).toBe('function');
  });

  it('should expose joinPath method', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.joinPath).toBe('function');
  });
});

describe('resolveWorkspaceUri', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('should resolve a workspace-relative path inside the workspace root', () => {
    const api = makeScopedWorkspaceApi();
    const result = resolveWorkspaceUri(api, 'src/file.txt');

    expect(result.fsPath).toBe('/Users/test/project/src/file.txt');
  });

  it('should allow an absolute path that stays within a workspace root', () => {
    const api = makeScopedWorkspaceApi();
    const result = resolveWorkspaceUri(api, '/Users/test/project/file.txt');

    expect(result.fsPath).toBe('/Users/test/project/file.txt');
  });

  it('should allow a file URI that stays within a workspace root', () => {
    const api = makeScopedWorkspaceApi();
    const result = resolveWorkspaceUri(api, 'file:///Users/test/project/file.txt');

    expect(result.fsPath).toBe('/Users/test/project/file.txt');
  });

  it('should resolve the workspace root for an empty relative path', () => {
    const api = makeScopedWorkspaceApi();
    const result = resolveWorkspaceUri(api, '');

    expect(result.fsPath).toBe('/Users/test/project');
  });

  it('should reject absolute paths outside the workspace root', () => {
    const api = makeScopedWorkspaceApi();
    expect(() => resolveWorkspaceUri(api, '/Users/test/elsewhere/file.txt')).toThrow('outside the opened workspace root');
  });

  it('should reject URI strings outside the workspace root', () => {
    const api = makeScopedWorkspaceApi();
    expect(() => resolveWorkspaceUri(api, 'file:///Users/test/elsewhere/file.txt')).toThrow('outside the opened workspace root');
  });

  it('should reject relative traversal outside the workspace root', () => {
    const api = makeScopedWorkspaceApi();
    expect(() => resolveWorkspaceUri(api, '../outside.txt')).toThrow('outside the opened workspace root');
  });

  it('should throw when no workspace folder is open', () => {
    const emptyApi = {
      workspaceFolders: undefined,
      parseUri: (value: string) => ({ scheme: '', fsPath: '', toString: () => value } as BurnBarWorkspaceUri),
      fileUri: (value: string) => ({ scheme: 'file', fsPath: value, toString: () => `file://${value}` } as BurnBarWorkspaceUri),
      joinPath: (base: BurnBarWorkspaceUri, ...segments: string[]) => ({ scheme: 'file', fsPath: segments.join('/'), toString: () => `file://${segments.join('/')}` } as BurnBarWorkspaceUri)
    };

    expect(() => resolveWorkspaceUri(emptyApi as any, 'relative/path.txt')).toThrow('Open a workspace folder');
  });
});

// Integration tests
describe('Workspace API Integration', () => {
  it('should resolve multiple workspace-contained paths in sequence', () => {
    const api = {
      workspaceFolders: [
        {
          uri: {
            scheme: 'file',
            fsPath: '/Users/test/project',
            toString: () => 'file:///Users/test/project'
          }
        }
      ],
      parseUri: (value: string) => ({ scheme: 'file', fsPath: value.replace(/^file:\/\//u, ''), toString: () => value }),
      fileUri: (value: string) => ({ scheme: 'file', fsPath: value, toString: () => `file://${value}` }),
      joinPath: (base: BurnBarWorkspaceUri, ...segments: string[]) => {
        const resolved = path.posix.resolve(base.fsPath, ...segments);
        return { scheme: base.scheme, fsPath: resolved, toString: () => `file://${resolved}` };
      }
    } satisfies Pick<BurnBarWorkspaceApi, 'workspaceFolders' | 'parseUri' | 'fileUri' | 'joinPath'>;

    const uri1 = resolveWorkspaceUri(api, '/Users/test/project/file.txt');
    const uri2 = resolveWorkspaceUri(api, 'src/index.ts');

    expect(uri1.fsPath).toBe('/Users/test/project/file.txt');
    expect(uri2.fsPath).toBe('/Users/test/project/src/index.ts');
  });
});

// Edge case tests
describe('Workspace API Edge Cases', () => {
  it('should allow unicode paths that stay inside the workspace root', () => {
    const api = makeScopedWorkspaceApi();
    const result = resolveWorkspaceUri(api, '/Users/test/project/Проект/file.txt');

    expect(result.fsPath).toBe('/Users/test/project/Проект/file.txt');
  });

  it('should allow spaces in paths that stay inside the workspace root', () => {
    const api = makeScopedWorkspaceApi();
    const result = resolveWorkspaceUri(api, '/Users/test/project/path with spaces/file.txt');

    expect(result.fsPath).toBe('/Users/test/project/path with spaces/file.txt');
  });

  it('should allow long paths that stay inside the workspace root', () => {
    const api = makeScopedWorkspaceApi();
    const longPath = `/Users/test/project/${'a'.repeat(500)}/file.txt`;
    const result = resolveWorkspaceUri(api, longPath);

    expect(result.fsPath).toBe(longPath);
  });
});

// API interface tests
describe('BurnBarWorkspaceApi Interface', () => {
  it('should have required properties', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect('hostKind' in api).toBe(true);
    expect('remoteName' in api).toBe(true);
    expect('isTrusted' in api).toBe(true);
    expect('workspaceFolders' in api).toBe(true);
  });

  it('should have required methods', () => {
    const api = createBurnBarWorkspaceApi('ui');

    expect(typeof api.isWritableFileSystem).toBe('function');
    expect(typeof api.readFile).toBe('function');
    expect(typeof api.findFiles).toBe('function');
    expect(typeof api.openTextDocument).toBe('function');
    expect(typeof api.applyEdit).toBe('function');
    expect(typeof api.saveAll).toBe('function');
    expect(typeof api.createWorkspaceEdit).toBe('function');
    expect(typeof api.createRange).toBe('function');
    expect(typeof api.createTerminal).toBe('function');
    expect(typeof api.parseUri).toBe('function');
    expect(typeof api.fileUri).toBe('function');
    expect(typeof api.joinPath).toBe('function');
  });
});

// Type tests
describe('BurnBarWorkspaceUri Interface', () => {
  it('should have required properties', () => {
    const api = makeScopedWorkspaceApi();
    const uri = resolveWorkspaceUri(api, '/Users/test/project/path.txt');

    expect('scheme' in uri).toBe(true);
    expect('fsPath' in uri).toBe(true);
    expect('toString' in uri).toBe(true);
  });

  it('toString should return string representation', () => {
    const api = makeScopedWorkspaceApi();
    const uri = resolveWorkspaceUri(api, '/Users/test/project/path.txt');

    expect(typeof uri.toString()).toBe('string');
  });
});
