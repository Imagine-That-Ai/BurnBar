import { execFile as nodeExecFile } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync as nodeExistsSync } from 'node:fs';
import { homedir, platform } from 'node:os';
import { join } from 'node:path';

const execFile = promisify(nodeExecFile);

export interface OpenBurnBarDaemonRuntimePaths {
  launchAgentPlistPath: string;
}

export interface OpenBurnBarRepairResult {
  message: string;
}

export interface OpenBurnBarRepairServiceLike {
  repair(): Promise<OpenBurnBarRepairResult>;
}

export interface OpenBurnBarRepairServiceOptions {
  execFile?: typeof execFile;
  existsSync?: (path: string) => boolean;
  platform?: NodeJS.Platform;
  uid?: number;
  paths?: OpenBurnBarDaemonRuntimePaths;
}

export const OPENBURNBAR_DAEMON_LAUNCH_AGENT_LABEL = 'com.openburnbar.daemon';

export function defaultOpenBurnBarRuntimePaths(): OpenBurnBarDaemonRuntimePaths {
  return {
    launchAgentPlistPath: join(homedir(), 'Library', 'LaunchAgents', `${OPENBURNBAR_DAEMON_LAUNCH_AGENT_LABEL}.plist`)
  };
}

export class OpenBurnBarRepairService implements OpenBurnBarRepairServiceLike {
  private readonly execFile: typeof execFile;
  private readonly existsSync: (path: string) => boolean;
  private readonly platform: NodeJS.Platform;
  private readonly uid: number;
  private readonly paths: OpenBurnBarDaemonRuntimePaths;

  constructor(options: OpenBurnBarRepairServiceOptions = {}) {
    this.execFile = options.execFile ?? execFile;
    this.existsSync = options.existsSync ?? nodeExistsSync;
    this.platform = options.platform ?? platform();
    this.uid = options.uid ?? process.getuid?.() ?? 0;
    this.paths = options.paths ?? defaultOpenBurnBarRuntimePaths();
  }

  async repair(): Promise<OpenBurnBarRepairResult> {
    if (this.platform !== 'darwin') {
      throw new Error('OpenBurnBar daemon repair is only available from the local macOS extension host.');
    }

    if (!this.existsSync(this.paths.launchAgentPlistPath)) {
      throw new Error('OpenBurnBar daemon is not installed yet. Install or repair it from the OpenBurnBar app first.');
    }

    const launchctlDomain = `gui/${this.uid}`;
    const launchctlServiceTarget = `${launchctlDomain}/${OPENBURNBAR_DAEMON_LAUNCH_AGENT_LABEL}`;

    try {
      if (await this.isServiceLoaded(launchctlServiceTarget)) {
        await this.execFile('/bin/launchctl', ['kickstart', '-k', launchctlServiceTarget]);
        return {
          message: 'OpenBurnBar daemon restart requested.'
        };
      }
    } catch (error) {
      if (!(await this.isServiceLoaded(launchctlServiceTarget))) {
        throw error;
      }
    }

    try {
      await this.execFile('/bin/launchctl', ['bootstrap', launchctlDomain, this.paths.launchAgentPlistPath]);
    } catch (error) {
      if (!(await this.isServiceLoaded(launchctlServiceTarget))) {
        throw error;
      }
    }

    try {
      await this.execFile('/bin/launchctl', ['kickstart', '-k', launchctlServiceTarget]);
    } catch (error) {
      if (!(await this.isServiceLoaded(launchctlServiceTarget))) {
        try {
          await this.execFile('/bin/launchctl', ['bootstrap', launchctlDomain, this.paths.launchAgentPlistPath]);
        } catch {
          // Ignore the retry bootstrap failure if the service appears on the next print probe.
        }

        if (!(await this.isServiceLoaded(launchctlServiceTarget))) {
          throw error;
        }
      }
    }

    return {
      message: 'OpenBurnBar daemon restart requested.'
    };
  }

  private async isServiceLoaded(serviceTarget: string): Promise<boolean> {
    try {
      await this.execFile('/bin/launchctl', ['print', serviceTarget]);
      return true;
    } catch {
      return false;
    }
  }
}
