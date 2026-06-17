import type * as vscode from 'vscode';
import { buildHostMessageNonceScript } from './hostMessageNonce';

export function buildPanelHtml(
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
    <title>OpenBurnBar</title>
    <link rel="stylesheet" href="${cssUri}" nonce="${nonce}" />
  </head>
  <body>
    <div id="bb-root">
      <header class="bb-header">
        <div class="bb-header-brand" aria-label="OpenBurnBar">
          <img class="bb-header-logo" src="${logoUri}" width="28" height="28" alt="" />
          <span class="bb-wordmark">OpenBurnBar</span>
        </div>
        <div class="bb-header-status">
          <span class="bb-orb bb-orb--connecting" aria-hidden="true"></span>
          <span class="bb-status-text" id="bb-status-text">\u2014</span>
        </div>
      </header>

      <div class="bb-recovery" data-visible="false">
        <div class="bb-recovery-header">
          <span class="bb-recovery-icon">\u26A0</span>
          <p class="bb-recovery-title">Daemon unavailable</p>
        </div>
        <p class="bb-recovery-msg" id="bb-recovery-msg"></p>
      </div>

      <section class="bb-active-summary" id="bb-active-summary" data-visible="false">
        <div class="bb-active-summary-header">
          <span class="bb-active-dot" id="bb-active-dot"></span>
          <span class="bb-active-title" id="bb-active-title">\u2014</span>
        </div>
        <div class="bb-active-meta" id="bb-active-meta"></div>
      </section>

      <section class="bb-launchers">
        <button class="bb-btn bb-btn--primary bb-launcher" data-action="openWorkspace">Open Workspace</button>
        <button class="bb-btn bb-btn--secondary bb-launcher" data-action="startRun">Start Run</button>
        <button class="bb-btn bb-btn--secondary bb-launcher" data-action="openApp" data-visible="false">Search Conversations</button>
      </section>

      <section class="bb-compact-actions">
        <button class="bb-icon-btn" data-action="refresh" title="Refresh">\u27F3</button>
        <button class="bb-icon-btn" data-action="repair" title="Repair daemon">\u2699</button>
        <button class="bb-header-app-btn" data-action="openApp" data-visible="false" title="Open OpenBurnBar dashboard">Dashboard</button>
      </section>

      <footer class="bb-status-line" id="bb-status-line" data-visible="false"></footer>
    </div>

    <script nonce="${nonce}">${buildHostMessageNonceScript(nonce)}</script>
    <script nonce="${nonce}" src="${jsUri}"></script>
  </body>
</html>`;
}
