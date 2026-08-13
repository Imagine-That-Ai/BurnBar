import type { PopupSnapshot } from '../shared/messages';
import {
  emptySafariPerformanceDiagnostics,
  type SafariPerformanceDiagnostics,
  type SafariPerformanceMetricName
} from '../shared/performance';

export const SAFARI_PERFORMANCE_LABELS: Record<SafariPerformanceMetricName, string> = {
  popup_bootstrap: 'Popup bootstrap',
  native_attach: 'Native attach',
  command_poll: 'Command poll',
  command_completion: 'Command completion',
  viewport_capture: 'Viewport capture',
  image_resize: 'Image resize',
  ask_first_token: 'Ask first token',
  action_verification: 'Action verification',
  stop_panic: 'Stop / abort',
  learning_load: 'Learning load',
  learning_mutation: 'Learning mutation'
};

export function formatPerformanceDuration(durationMs: number): string {
  if (durationMs < 1) {
    return `${durationMs.toFixed(2)} ms`;
  }
  if (durationMs < 1_000) {
    return `${durationMs.toFixed(durationMs < 10 ? 1 : 0)} ms`;
  }
  return `${(durationMs / 1_000).toFixed(durationMs < 10_000 ? 2 : 1)} s`;
}

interface SafariPerformanceExport {
  schemaVersion: 1;
  exportedAt: string;
  extension: {
    version: string;
    daemonVersion: string | null;
  };
  privacy: {
    localOnly: true;
    excludes: string[];
  };
  performance: SafariPerformanceDiagnostics;
}

export function buildSafariPerformanceExport(
  snapshot: PopupSnapshot | undefined,
  extensionVersion: string,
  exportedAt = new Date()
): SafariPerformanceExport {
  return {
    schemaVersion: 1,
    exportedAt: exportedAt.toISOString(),
    extension: {
      version: extensionVersion,
      daemonVersion: snapshot?.bridge.daemonVersion ?? null
    },
    privacy: {
      localOnly: true,
      excludes: [
        'URLs',
        'page titles',
        'prompts',
        'page text',
        'screenshots',
        'model and provider identifiers',
        'tokens and credentials',
        'tab and command identifiers'
      ]
    },
    performance: snapshot?.performance ?? emptySafariPerformanceDiagnostics()
  };
}

export function safariPerformanceExportFilename(exportedAt = new Date()): string {
  const timestamp = exportedAt.toISOString().replaceAll(':', '-');
  return `openburnbar-safari-performance-${timestamp}.json`;
}
