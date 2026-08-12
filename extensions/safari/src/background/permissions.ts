import type { BrowserAPI } from '../shared/browser';
import { SafariExtensionError } from '../shared/errors';

export type SitePermissionStatus = 'granted' | 'prompt' | 'denied' | 'unsupported';

export function permissionPatternForURL(urlValue: string): string {
  let url: URL;
  try {
    url = new URL(urlValue);
  } catch {
    throw new SafariExtensionError('unsupported_page', 'The active tab does not have a valid web URL.');
  }
  if (!['http:', 'https:'].includes(url.protocol)) {
    throw new SafariExtensionError('unsupported_page', 'OpenBurnBar can only read regular HTTP and HTTPS pages.');
  }
  return `${url.origin}/*`;
}

export class SitePermissionController {
  constructor(private readonly browserAPI: BrowserAPI) {}

  async status(url: string): Promise<SitePermissionStatus> {
    try {
      const pattern = permissionPatternForURL(url);
      return (await this.browserAPI.permissions.contains({ origins: [pattern] })) ? 'granted' : 'prompt';
    } catch (error) {
      if (error instanceof SafariExtensionError) {
        return 'unsupported';
      }
      return 'denied';
    }
  }

  async request(url: string): Promise<SitePermissionStatus> {
    const pattern = permissionPatternForURL(url);
    try {
      return (await this.browserAPI.permissions.request({ origins: [pattern] })) ? 'granted' : 'denied';
    } catch {
      return 'denied';
    }
  }

  async revoke(url: string): Promise<boolean> {
    const pattern = permissionPatternForURL(url);
    return this.browserAPI.permissions.remove({ origins: [pattern] });
  }
}
