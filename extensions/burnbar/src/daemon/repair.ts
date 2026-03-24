import { execFile as nodeExecFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync as nodeExistsSync } from "node:fs";
import { homedir, platform } from "node:os";
import { join } from "node:path";

const execFile = promisify(nodeExecFile);

export interface BurnBarDaemonRuntimePaths {
  launchAgentPlistPath: string;
}

export interface BurnBarRepairResult {
  message: string;
}

export interface BurnBarRepairServiceLike {
  repair(): Promise<BurnBarRepairResult>;
}

export interface BurnBarRepairServiceOptions {
  execFile?: typeof execFile;
  existsSync?: (path: string) => boolean;
  platform?: NodeJS.Platform;
  uid?: number;
  paths?: BurnBarDaemonRuntimePaths;
}

export const BURNBAR_DAEMON_LAUNCH_AGENT_LABEL = "com.burnbar.daemon";

export function defaultBurnBarRuntimePaths(): BurnBarDaemonRuntimePaths {
  return {
    launchAgentPlistPath: join(
      homedir(),
      "Library",
      "LaunchAgents",
      `${BURNBAR_DAEMON_LAUNCH_AGENT_LABEL}.plist`
    )
  };
}

export class BurnBarRepairService implements BurnBarRepairServiceLike {
  private readonly execFile: typeof execFile;
  private readonly existsSync: (path: string) => boolean;
  private readonly platform: NodeJS.Platform;
  private readonly uid: number;
  private readonly paths: BurnBarDaemonRuntimePaths;

  constructor(options: BurnBarRepairServiceOptions = {}) {
    this.execFile = options.execFile ?? execFile;
    this.existsSync = options.existsSync ?? nodeExistsSync;
    this.platform = options.platform ?? platform();
    this.uid = options.uid ?? process.getuid?.() ?? 0;
    this.paths = options.paths ?? defaultBurnBarRuntimePaths();
  }

  async repair(): Promise<BurnBarRepairResult> {
    if (this.platform !== "darwin") {
      throw new Error("BurnBar daemon repair is only available from the local macOS extension host.");
    }

    if (!this.existsSync(this.paths.launchAgentPlistPath)) {
      throw new Error("BurnBar daemon is not installed yet. Install or repair it from the BurnBar app first.");
    }

    const launchctlDomain = `gui/${this.uid}`;
    const launchctlServiceTarget = `${launchctlDomain}/${BURNBAR_DAEMON_LAUNCH_AGENT_LABEL}`;

    try {
      if (await this.isServiceLoaded(launchctlServiceTarget)) {
        await this.execFile("/bin/launchctl", ["kickstart", "-k", launchctlServiceTarget]);
        return {
          message: "BurnBar daemon restart requested."
        };
      }
    } catch (error) {
      if (!(await this.isServiceLoaded(launchctlServiceTarget))) {
        throw error;
      }
    }

    try {
      await this.execFile("/bin/launchctl", ["bootstrap", launchctlDomain, this.paths.launchAgentPlistPath]);
    } catch (error) {
      if (!(await this.isServiceLoaded(launchctlServiceTarget))) {
        throw error;
      }
    }

    try {
      await this.execFile("/bin/launchctl", ["kickstart", "-k", launchctlServiceTarget]);
    } catch (error) {
      if (!(await this.isServiceLoaded(launchctlServiceTarget))) {
        try {
          await this.execFile("/bin/launchctl", ["bootstrap", launchctlDomain, this.paths.launchAgentPlistPath]);
        } catch {
          // Ignore the retry bootstrap failure if the service appears on the next print probe.
        }

        if (!(await this.isServiceLoaded(launchctlServiceTarget))) {
          throw error;
        }
      }
    }

    return {
      message: "BurnBar daemon restart requested."
    };
  }

  private async isServiceLoaded(serviceTarget: string): Promise<boolean> {
    try {
      await this.execFile("/bin/launchctl", ["print", serviceTarget]);
      return true;
    } catch {
      return false;
    }
  }
}
