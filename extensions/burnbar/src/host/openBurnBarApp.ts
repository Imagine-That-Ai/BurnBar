import { execFile } from "node:child_process";
import { promisify } from "node:util";

import * as vscode from "vscode";

const execFileAsync = promisify(execFile);
const BURNBAR_MACOS_BUNDLE_ID = "com.burnbar.app";

export type BurnBarAppLaunchTarget = "dashboard" | "search";

export async function openBurnBarApp(target: BurnBarAppLaunchTarget): Promise<void> {
  if (process.platform !== "darwin") {
    throw new Error("BurnBar app launching is currently supported on macOS only.");
  }

  const urls =
    target === "search"
      ? ["burnbar://search", "burnbar://dashboard"]
      : ["burnbar://dashboard"];

  for (const url of urls) {
    try {
      await execFileAsync("open", [url]);
      return;
    } catch {
      // Try the next launch target before falling back to the bundle open.
    }
  }

  await execFileAsync("open", ["-b", BURNBAR_MACOS_BUNDLE_ID]);
}

export async function openBurnBarAppOrWarn(
  target: BurnBarAppLaunchTarget,
  missingMessage: string
): Promise<void> {
  try {
    await openBurnBarApp(target);
  } catch {
    void vscode.window.showWarningMessage(missingMessage);
  }
}
