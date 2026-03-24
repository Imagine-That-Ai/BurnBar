import { describe, expect, it, vi } from "vitest";

import { BURNBAR_DAEMON_LAUNCH_AGENT_LABEL, BurnBarRepairService } from "../src/daemon/repair";

describe("BurnBarRepairService", () => {
  it("kickstarts an already loaded service without unloading it first", async () => {
    const execFile = vi.fn(async (_cmd: string, args: string[]) => {
      if (args[0] === "print") {
        return { stdout: "loaded", stderr: "" };
      }
      if (args[0] === "kickstart") {
        return { stdout: "", stderr: "" };
      }
      throw new Error(`Unexpected launchctl call: ${args.join(" ")}`);
    });

    const service = new BurnBarRepairService({
      execFile,
      existsSync: () => true,
      platform: "darwin",
      uid: 501,
      paths: {
        launchAgentPlistPath: "/Users/test/Library/LaunchAgents/com.burnbar.daemon.plist"
      }
    });

    await expect(service.repair()).resolves.toMatchObject({
      message: expect.stringContaining("restart requested")
    });

    expect(execFile).toHaveBeenNthCalledWith(1, "/bin/launchctl", [
      "print",
      `gui/501/${BURNBAR_DAEMON_LAUNCH_AGENT_LABEL}`
    ]);
    expect(execFile).toHaveBeenNthCalledWith(2, "/bin/launchctl", [
      "kickstart",
      "-k",
      `gui/501/${BURNBAR_DAEMON_LAUNCH_AGENT_LABEL}`
    ]);
  });

  it("bootstraps the service when launchctl print says it is not loaded", async () => {
    const execFile = vi.fn(async (_cmd: string, args: string[]) => {
      if (args[0] === "print") {
        throw new Error("service not loaded");
      }
      if (args[0] === "bootstrap" || args[0] === "kickstart") {
        return { stdout: "", stderr: "" };
      }
      throw new Error(`Unexpected launchctl call: ${args.join(" ")}`);
    });

    const service = new BurnBarRepairService({
      execFile,
      existsSync: () => true,
      platform: "darwin",
      uid: 501,
      paths: {
        launchAgentPlistPath: "/Users/test/Library/LaunchAgents/com.burnbar.daemon.plist"
      }
    });

    await expect(service.repair()).resolves.toMatchObject({
      message: expect.stringContaining("restart requested")
    });

    expect(execFile).toHaveBeenCalledWith("/bin/launchctl", [
      "bootstrap",
      "gui/501",
      "/Users/test/Library/LaunchAgents/com.burnbar.daemon.plist"
    ]);
    expect(execFile).toHaveBeenCalledWith("/bin/launchctl", [
      "kickstart",
      "-k",
      `gui/501/${BURNBAR_DAEMON_LAUNCH_AGENT_LABEL}`
    ]);
  });

  it("treats kickstart not-found as recoverable when the service appears loaded on recheck", async () => {
    let printCalls = 0;
    const execFile = vi.fn(async (_cmd: string, args: string[]) => {
      if (args[0] === "print") {
        printCalls += 1;
        if (printCalls === 1) {
          throw new Error("service not loaded");
        }
        return { stdout: "loaded", stderr: "" };
      }
      if (args[0] === "bootstrap") {
        return { stdout: "", stderr: "" };
      }
      if (args[0] === "kickstart") {
        throw new Error(`Could not find service "${BURNBAR_DAEMON_LAUNCH_AGENT_LABEL}"`);
      }
      throw new Error(`Unexpected launchctl call: ${args.join(" ")}`);
    });

    const service = new BurnBarRepairService({
      execFile,
      existsSync: () => true,
      platform: "darwin",
      uid: 501,
      paths: {
        launchAgentPlistPath: "/Users/test/Library/LaunchAgents/com.burnbar.daemon.plist"
      }
    });

    await expect(service.repair()).resolves.toMatchObject({
      message: expect.stringContaining("restart requested")
    });
  });
});
