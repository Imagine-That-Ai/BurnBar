import type {
  BurnBarWorkspaceApi,
  BurnBarWorkspaceFolder,
  BurnBarWorkspaceUri
} from '../../src/workspace/api';

export function createMockWorkspaceUri(
  fsPath: string,
  scheme = 'file'
): BurnBarWorkspaceUri {
  return {
    scheme,
    fsPath,
    toString: () => (scheme === 'file' ? `file://${fsPath}` : `${scheme}:${fsPath}`)
  };
}

export function createMockWorkspaceFolder(fsPath: string): BurnBarWorkspaceFolder {
  return { uri: createMockWorkspaceUri(fsPath) };
}

export function createMockWorkspaceUriHelpers(): Pick<
  BurnBarWorkspaceApi,
  'parseUri' | 'fileUri' | 'joinPath'
> {
  return {
    parseUri: (value: string) => {
      const scheme = value.split(':')[0] ?? 'file';
      const fsPath = scheme === 'file' ? value.replace(/^file:\/\//u, '') : value;
      return createMockWorkspaceUri(fsPath, scheme);
    },
    fileUri: (value: string) => createMockWorkspaceUri(value),
    joinPath: (base: BurnBarWorkspaceUri, ...segments: string[]) =>
      createMockWorkspaceUri([base.fsPath, ...segments].join('/'), base.scheme)
  };
}

export function createEmptyWorkspaceUriApi(): Pick<
  BurnBarWorkspaceApi,
  'workspaceFolders' | 'parseUri' | 'fileUri' | 'joinPath'
> {
  const uriHelpers = createMockWorkspaceUriHelpers();
  return {
    workspaceFolders: undefined,
    ...uriHelpers
  };
}
