import type * as vscode from 'vscode';
import { buildHostMessageNonceScript } from './hostMessageNonce';

export function buildWorkspaceHtml(
  webview: vscode.Webview,
  cssUri: vscode.Uri,
  jsUri: vscode.Uri,
  logoUri: vscode.Uri,
  nonce: string
): string {
  return `<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta
      http-equiv="Content-Security-Policy"
      content="default-src 'none'; img-src ${webview.cspSource}; style-src ${webview.cspSource} 'nonce-${nonce}'; script-src 'nonce-${nonce}';"
    />
    <title>OpenBurnBar Workspace</title>
    <link rel="stylesheet" href="${cssUri}" nonce="${nonce}" />
  </head>
  <body>
    <div class="bw-workspace">

      <!-- ── Section Rail ─────────────────────────────── -->
      <nav class="bw-rail" aria-label="OpenBurnBar sections">
        <div class="bw-rail-brand">
          <img class="bw-rail-logo" src="${logoUri}" width="26" height="26" alt="OpenBurnBar" />
        </div>
        <div class="bw-rail-divider"></div>

        <div class="bw-rail-sections">
          <button class="bw-rail-btn bw-rail-btn--active" data-section="command" title="Command" aria-label="Command section">
            <svg width="18" height="18" viewBox="0 0 20 20" fill="none" aria-hidden="true">
              <path d="M4 7l4 3-4 3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
              <path d="M10 14h6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
            </svg>
          </button>
          <button class="bw-rail-btn" data-section="runs" title="Runs" aria-label="Runs section">
            <svg width="18" height="18" viewBox="0 0 20 20" fill="none" aria-hidden="true">
              <rect x="3" y="4" width="14" height="2" rx="1" fill="currentColor" opacity="0.9"/>
              <rect x="3" y="9" width="10" height="2" rx="1" fill="currentColor" opacity="0.55"/>
              <rect x="3" y="14" width="12" height="2" rx="1" fill="currentColor" opacity="0.3"/>
            </svg>
          </button>
          <button class="bw-rail-btn" data-section="system" title="System" aria-label="System section">
            <svg width="18" height="18" viewBox="0 0 20 20" fill="none" aria-hidden="true">
              <circle cx="7" cy="6" r="2" stroke="currentColor" stroke-width="1.5"/>
              <circle cx="13" cy="14" r="2" stroke="currentColor" stroke-width="1.5"/>
              <path d="M7 8v8M7 4v0M13 4v8M13 16v0" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
            </svg>
          </button>
        </div>

        <div class="bw-rail-spacer"></div>
        <div class="bw-rail-divider"></div>

        <div class="bw-rail-footer">
          <button class="bw-rail-btn" data-action="openConversationSearch" title="Search conversations" aria-label="Search conversations">
            <svg width="18" height="18" viewBox="0 0 20 20" fill="none" aria-hidden="true">
              <circle cx="9" cy="9" r="5" stroke="currentColor" stroke-width="1.5"/>
              <path d="M13 13l3.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
            </svg>
          </button>
        </div>
      </nav>

      <!-- ── Canvas ───────────────────────────────────── -->
      <main class="bw-canvas">

        <!-- Command Section -->
        <section class="bw-section bw-section--active" data-section="command">
          <div class="bw-section-scroll">
            <div id="bw-command-run"></div>
            <div id="bw-command-timeline"></div>
          </div>

          <div class="bw-composer">
            <textarea class="bw-composer-input" placeholder="Describe what OpenBurnBar should do\u2026" rows="3" aria-label="Run prompt"></textarea>
            <div class="bw-composer-controls">
              <select class="bw-model-select" aria-label="Model"></select>
              <div class="bw-mode-chips">
                <button class="bw-mode-chip bw-mode-chip--active" data-mode="explain">Explain</button>
                <button class="bw-mode-chip" data-mode="fix">Fix</button>
                <button class="bw-mode-chip" data-mode="inspect">Inspect</button>
              </div>
              <button class="bw-btn bw-btn--primary bw-btn--sm" data-action="startRun">Start Run</button>
            </div>
            <p class="bw-composer-disabled-msg" data-visible="false"></p>
          </div>
        </section>

        <!-- Runs Section -->
        <section class="bw-section" data-section="runs">
          <div class="bw-section-header">
            <h2 class="bw-section-title">Runs</h2>
            <div class="bw-section-actions">
              <button class="bw-btn bw-btn--secondary bw-btn--sm" data-action="refresh">Refresh</button>
            </div>
          </div>
          <div class="bw-runs-scroll">
            <div class="bw-runs-ledger" id="bw-runs-ledger"></div>
          </div>
        </section>

        <!-- System Section -->
        <section class="bw-section" data-section="system">
          <div class="bw-section-header">
            <h2 class="bw-section-title">System</h2>
          </div>
          <div class="bw-system-scroll">
            <div class="bw-system-grid" id="bw-system-grid"></div>
          </div>
        </section>

      </main>

      <!-- ── Inspector ────────────────────────────────── -->
      <aside class="bw-inspector" aria-label="Run inspector">
        <div class="bw-inspector-header">
          <h3 class="bw-inspector-title">Inspector</h3>
        </div>
        <div class="bw-inspector-content" id="bw-inspector-content"></div>
      </aside>

    </div>

    <script nonce="${nonce}">${buildHostMessageNonceScript(nonce)}</script>
    <script nonce="${nonce}" src="${jsUri}"></script>
  </body>
</html>`;
}
