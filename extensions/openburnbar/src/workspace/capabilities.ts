import type { BurnBarWorkspaceApi } from './api';
import type { BurnBarWorkspaceCapabilities, BurnBarWorkspaceToolName } from './types';

export function detectWorkspaceCapabilities(
  api: Pick<BurnBarWorkspaceApi, 'hostKind' | 'remoteName' | 'isTrusted' | 'workspaceFolders' | 'isWritableFileSystem'>
): BurnBarWorkspaceCapabilities {
  const workspaceFolders = api.workspaceFolders ?? [];
  const folderSchemes = [...new Set(workspaceFolders.map((folder) => folder.uri.scheme))];
  const hasWorkspace = workspaceFolders.length > 0;
  const remoteWorkspace = hasWorkspace && Boolean(api.remoteName);
  const localWorkspace = hasWorkspace && !remoteWorkspace;
  const virtualWorkspace = hasWorkspace && folderSchemes.some((scheme) => scheme !== 'file');
  const readonlyWorkspace =
    hasWorkspace &&
    folderSchemes.length > 0 &&
    folderSchemes.every((scheme) => api.isWritableFileSystem(scheme) === false);
  const untrustedWorkspace = !api.isTrusted;

  const availableTools: BurnBarWorkspaceToolName[] = [];
  const gatedTools: BurnBarWorkspaceToolName[] = [];

  if (hasWorkspace) {
    availableTools.push('read_file', 'search_workspace');
  }

  if (hasWorkspace && !readonlyWorkspace && !untrustedWorkspace) {
    availableTools.push('apply_patch');
  } else if (hasWorkspace) {
    gatedTools.push('apply_patch');
  }

  if (hasWorkspace && !virtualWorkspace && !untrustedWorkspace) {
    availableTools.push('run_terminal');
  } else if (hasWorkspace) {
    gatedTools.push('run_terminal');
  }

  return {
    hasWorkspace,
    localWorkspace,
    remoteWorkspace,
    readonlyWorkspace,
    virtualWorkspace,
    untrustedWorkspace,
    workspaceHost: api.hostKind,
    availableTools,
    gatedTools,
    explanation: explainWorkspaceCapabilities({
      hasWorkspace,
      localWorkspace,
      remoteWorkspace,
      readonlyWorkspace,
      virtualWorkspace,
      untrustedWorkspace
    })
  };
}

function explainWorkspaceCapabilities(capabilities: {
  hasWorkspace: boolean;
  localWorkspace: boolean;
  remoteWorkspace: boolean;
  readonlyWorkspace: boolean;
  virtualWorkspace: boolean;
  untrustedWorkspace: boolean;
}): string {
  if (!capabilities.hasWorkspace) {
    return 'Open a workspace folder to enable OpenBurnBar file, search, edit, and terminal tools.';
  }

  const segments: string[] = [];

  segments.push(
    capabilities.remoteWorkspace
      ? 'Workspace tools are running on the remote workspace host.'
      : capabilities.localWorkspace
        ? 'Workspace tools are running in the local extension host.'
        : 'Workspace tools are available in the current host.'
  );

  if (capabilities.untrustedWorkspace) {
    segments.push(
      'This workspace is in restricted mode, so OpenBurnBar will not apply patches or run terminal commands until you trust it.'
    );
  }

  if (capabilities.readonlyWorkspace) {
    segments.push(
      'The workspace filesystem is read-only, so OpenBurnBar can read and search files but cannot write edits.'
    );
  }

  if (capabilities.virtualWorkspace) {
    segments.push('The workspace uses a virtual filesystem, so terminal execution is unavailable from OpenBurnBar.');
  }

  if (segments.length === 1) {
    segments.push('All workspace tools are available.');
  }

  return segments.join(' ');
}
