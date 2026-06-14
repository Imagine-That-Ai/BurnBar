/**
 * Extension health monitoring and alerting.
 *
 * Monitors daemon connectivity, workspace trust, and run lifecycle health.
 * Fires VS Code-level warning/error notifications and writes structured
 * alerts to the extension output channel for observability tooling.
 *
 * ## Alert channels
 * - VS Code notification (user-facing, for P0/P1 events only)
 * - Output channel (machine-readable, for all events)
 * - `vscode.window.setStatusBarMessage` for ambient status
 */

import * as vscode from 'vscode';
import { logger } from './logger';

// ── Alert severity ────────────────────────────────────────────────────────────

const AlertSeverity = {
  P0: 'P0', // Critical — extension is broken, user action required immediately
  P1: 'P1', // High — significant degradation, user should act soon
  P2: 'P2', // Medium — non-critical issue, informational notification
  P3: 'P3' // Low — background observation, no notification
} as const;

type AlertSeverityLevel = (typeof AlertSeverity)[keyof typeof AlertSeverity];

// ── Alert payload ─────────────────────────────────────────────────────────────

interface ExtensionAlert {
  /** Short machine-readable event identifier (snake_case). */
  event: string;
  /** Human-readable description shown in notifications and output channel. */
  message: string;
  /** Severity determines whether a VS Code notification is shown. */
  severity: AlertSeverityLevel;
  /** Optional action shown on the notification button. */
  action?: { label: string; command: string; args?: unknown[] };
  /** Structured context for observability tooling. */
  context?: Record<string, unknown>;
}

// ── Alert handler ─────────────────────────────────────────────────────────────

let _outputChannel: vscode.OutputChannel | undefined;

function outputChannel(): vscode.OutputChannel {
  if (!_outputChannel) {
    _outputChannel = vscode.window.createOutputChannel('OpenBurnBar Alerts', { log: true });
  }
  return _outputChannel;
}

/**
 * Fires an alert through all configured channels.
 *
 * P0/P1 → VS Code error/warning notification + output channel
 * P2     → VS Code information notification + output channel
 * P3     → output channel only (no intrusive popup)
 */
async function alert(a: ExtensionAlert): Promise<void> {
  const ts = new Date().toISOString();
  const logLine = `[${ts}] [${a.severity}] ${a.event}: ${a.message}`;

  // Always write to output channel (machine-readable for observability tools)
  outputChannel().appendLine(logLine);
  if (a.context) {
    outputChannel().appendLine(`  context: ${JSON.stringify(a.context)}`);
  }

  // Log through the scrubbing logger
  if (a.severity === AlertSeverity.P0 || a.severity === AlertSeverity.P1) {
    logger.error(logLine, a.context);
  } else {
    logger.warn(logLine, a.context);
  }

  // Show VS Code notification for P0/P1/P2
  if (a.severity === AlertSeverity.P3) {
    return; // Silent observation only
  }

  const actionLabel = a.action?.label;
  let response: string | undefined;

  if (a.severity === AlertSeverity.P0 || a.severity === AlertSeverity.P1) {
    response = await vscode.window.showErrorMessage(`OpenBurnBar: ${a.message}`, ...(actionLabel ? [actionLabel] : []));
  } else {
    response = await vscode.window.showInformationMessage(
      `OpenBurnBar: ${a.message}`,
      ...(actionLabel ? [actionLabel] : [])
    );
  }

  if (response === actionLabel && a.action) {
    await vscode.commands.executeCommand(a.action.command, ...(a.action.args ?? []));
  }
}

// ── Preset alerts ─────────────────────────────────────────────────────────────

/** Fires when the daemon socket is unreachable for > 30s. */
export function alertDaemonUnreachable(socketPath: string): void {
  void alert({
    event: 'daemon_unreachable',
    message: 'Cannot connect to the OpenBurnBar daemon. Token tracking is paused.',
    severity: AlertSeverity.P1,
    action: {
      label: 'Repair',
      command: 'openburnbar.repairDaemon'
    },
    context: { socketPath }
  });
}
