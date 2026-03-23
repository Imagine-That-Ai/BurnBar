import type * as vscode from "vscode";

export function buildPanelHtml(
  webview: vscode.Webview,
  cssUri: vscode.Uri,
  jsUri: vscode.Uri,
  nonce: string
): string {
  return `<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta
      http-equiv="Content-Security-Policy"
      content="default-src 'none'; style-src ${webview.cspSource} 'nonce-${nonce}'; script-src 'nonce-${nonce}';"
    />
    <title>BurnBar</title>
    <link rel="stylesheet" href="${cssUri}" nonce="${nonce}" />
  </head>
  <body>
    <div id="bb-root">
      <header class="bb-header">
        <span class="bb-wordmark">BurnBar</span>
        <div class="bb-header-chips">
          <span class="bb-orb bb-orb--connecting"></span>
          <span class="bb-chip" id="bb-workspace-chip">—</span>
        </div>
        <div class="bb-header-actions">
          <button class="bb-icon-btn" data-action="refresh" title="Refresh">⟳</button>
          <button class="bb-icon-btn" data-action="repair" title="Repair daemon">⚙</button>
        </div>
      </header>

      <div class="bb-recovery" data-visible="false">
        <div class="bb-recovery-header">
          <span class="bb-recovery-icon">⚠</span>
          <p class="bb-recovery-title">BurnBar daemon unavailable</p>
        </div>
        <p class="bb-recovery-msg" id="bb-recovery-msg"></p>
        <div class="bb-recovery-actions">
          <button class="bb-btn bb-btn--secondary" data-action="refresh">Reconnect</button>
          <button class="bb-btn bb-btn--secondary" data-action="repair">Repair daemon</button>
        </div>
      </div>

      <section class="bb-composer">
        <textarea class="bb-composer-input" placeholder="Describe what BurnBar should do…" rows="3"></textarea>
        <div class="bb-composer-controls">
          <select class="bb-model-select"></select>
          <div class="bb-mode-chips">
            <button class="bb-mode-chip bb-mode-chip--active" data-mode="explain">Explain</button>
            <button class="bb-mode-chip" data-mode="fix">Fix</button>
            <button class="bb-mode-chip" data-mode="inspect">Inspect</button>
          </div>
        </div>
        <button class="bb-btn bb-btn--primary bb-start-run" data-action="startRun">Start Run</button>
        <p class="bb-composer-disabled-msg" data-visible="false"></p>
      </section>

      <section class="bb-runs" id="bb-runs">
        <!-- Active run card injected before history by JS -->
        <div class="bb-history-runs" id="bb-history-runs"></div>
        <div class="bb-no-runs-msg" id="bb-no-runs-msg" data-visible="false">
          Start a run to see BurnBar control the daemon here.
        </div>
      </section>

      <section class="bb-capabilities" id="bb-capabilities">
        <!-- Capability chips rendered by JS -->
      </section>

      <details class="bb-system-drawer">
        <summary class="bb-system-drawer-summary">System</summary>
        <div class="bb-system-content" id="bb-system-content">
          <!-- Key-value rows rendered by JS -->
        </div>
      </details>
    </div>

    <script nonce="${nonce}" src="${jsUri}"></script>
  </body>
</html>`;
}
