import {
  PROVIDER_CAPABILITIES,
  type ProviderCapabilityRow
} from './generated/providerCapabilities.generated.js';

export type ProviderPathRow = ProviderCapabilityRow;
export const LINUX_PROVIDER_PATH_REGISTRY: readonly ProviderPathRow[] = PROVIDER_CAPABILITIES;

export function resolveProviderLogicalPath(
  logicalPath: string,
  home: string,
  env: {
    XDG_CONFIG_HOME?: string;
    XDG_DATA_HOME?: string;
    OPENBURNBAR_PROVIDER_HOME?: string;
    SNAP_REAL_HOME?: string;
  } = {}
): string {
  if (!logicalPath.startsWith('~')) return logicalPath;
  const providerHome = env.OPENBURNBAR_PROVIDER_HOME || env.SNAP_REAL_HOME || home;
  const rest = logicalPath === '~' ? '' : logicalPath.slice(1);
  if (rest.startsWith('/.config/') && env.XDG_CONFIG_HOME) {
    return env.XDG_CONFIG_HOME + rest.slice('/.config'.length);
  }
  if (rest.startsWith('/.local/share/') && env.XDG_DATA_HOME) {
    return env.XDG_DATA_HOME + rest.slice('/.local/share'.length);
  }
  return providerHome + rest;
}

export function providerPathById(providerId: string): ProviderPathRow | undefined {
  return LINUX_PROVIDER_PATH_REGISTRY.find((row) => row.providerId === providerId);
}

export function providerDisplayPaths(): string[] {
  return LINUX_PROVIDER_PATH_REGISTRY.flatMap((row) =>
    row.linuxLogicalPath === null ? [] : [row.linuxLogicalPath]
  );
}
