import { execFile } from "node:child_process";
import { LOCAL_CLIPROXY_KEY, openaiGatewayUrl, anthropicGatewayUrl } from "./proxyAuth.js";
import { proxySnippets } from "./proxySnippets.js";
import { getBrandLogoDataUri } from "./proxyBrandLogos.js";

export function gatewayPanelUrl(port: number): string {
  return `http://127.0.0.1:${port}/gateway`;
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/gu, "&amp;")
    .replace(/</gu, "&lt;")
    .replace(/>/gu, "&gt;")
    .replace(/"/gu, "&quot;")
    .replace(/'/gu, "&#39;");
}

function clientGlyph(id: string, title: string): string {
  const dataUri = getBrandLogoDataUri(id);
  if (dataUri) {
    return `<img class="client-glyph-img" src="${dataUri}" alt="${escapeHtml(title)}" width="36" height="36" />`;
  }
  return `<span class="client-glyph-fallback">${escapeHtml(title.charAt(0))}</span>`;
}

export function gatewayPanelHtml(port: number, requireToken = false): string {
  const snippets = proxySnippets(port);
  const localKeyText = requireToken
    ? "disabled (--require-token): send your private token"
    : LOCAL_CLIPROXY_KEY;
  const openaiUrl = openaiGatewayUrl(port);
  const anthropicUrl = anthropicGatewayUrl(port);

  const snippetCards = snippets
    .map((snippet) => {
      const id = escapeHtml(snippet.id);
      const title = escapeHtml(snippet.title);
      const caveat = escapeHtml(snippet.caveat);
      const body = escapeHtml(snippet.body);
      const glyph = clientGlyph(snippet.id, snippet.title);
      const isWireable = ["grok", "droid-generic", "claude-code", "codex", "opencode", "forge", "pi"].includes(snippet.id);
      const wireClientName = snippet.id === "claude-code" ? "claude" : snippet.id === "droid-generic" ? "droid" : snippet.id;
      const wirePill = isWireable
        ? `<div class="wire-row"><span class="wire-tag">CLI Wire</span><button class="wire-code-pill" onclick="copySnippet('openburnbar proxy wire ${wireClientName} --write', this)" aria-label="Copy auto-wire command for ${title}"><code>openburnbar proxy wire ${wireClientName} --write</code></button></div>`
        : "";

      return `
    <article class="glass-card client-tile" data-client="${id}">
      <div class="tile-top">
        <div class="glyph-and-title">
          <div class="glyph-frame">${glyph}</div>
          <div>
            <h3 class="tile-heading">${title}</h3>
            <span class="tile-id">${id}</span>
          </div>
        </div>
        <button class="copy-action-btn" onclick="copySnippetText(this)" aria-label="Copy snippet for ${title}">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
          <span>Copy</span>
        </button>
      </div>
      <p class="tile-caveat">${caveat}</p>
      <div class="code-box">
        <pre><code class="raw-snippet">${body}</code></pre>
      </div>
      ${wirePill}
    </article>`;
    })
    .join("\n");

  return `<!DOCTYPE html>
<html lang="en" data-theme="system">
<head>
<meta charset="utf-8">
<title>OpenBurnBar Gateway · :${port}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
/* Adaptive Theme Tokens — BurnBar System */
:root {
  /* Default: Dark Warm Charcoal */
  --bg-page: #0E0D0B;
  --bg-card: rgba(23, 21, 16, 0.82);
  --bg-elevated: #201E18;
  --bg-code: #080706;
  --border: #302C22;
  --border-subtle: #1E1C16;
  --border-focus: #FFA800;
  --border-ember: rgba(250, 80, 83, 0.45);
  --text-bright: #FFFFFF;
  --text-primary: #F0EBE2;
  --text-secondary: #9A9088;
  --text-muted: #7A7268;
  --success: #38D898;
  --warning: #FFA800;
  --ember: #FA5053;
  --blaze: #E86100;
  --gold: #D4AA3C;
  --glyph-bg-color: #1C1814;
  --glyph-path-fill: #F0EBE2;
  --glyph-emerald-bg: #103628;
  --glyph-gold-bg: #2E2010;
  --glow-opacity: 0.35;
  --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "JetBrains Mono", monospace;
  --font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif;
  --radius-sm: 6px;
  --radius-md: 10px;
  --radius-lg: 16px;
  --glass-blur: blur(32px);
}

/* Light Botanical Cream Palette */
html[data-theme="light"],
@media (prefers-color-scheme: light) {
  html[data-theme="system"] {
    --bg-page: #F6F4EF;
    --bg-card: rgba(255, 254, 251, 0.88);
    --bg-elevated: #EDEAE1;
    --bg-code: #EAE6DB;
    --border: rgba(22, 20, 15, 0.12);
    --border-subtle: rgba(22, 20, 15, 0.08);
    --border-focus: #D97706;
    --border-ember: rgba(244, 91, 105, 0.35);
    --text-bright: #16140F;
    --text-primary: #2C2820;
    --text-secondary: #5E584D;
    --text-muted: #8E8678;
    --success: #0D9488;
    --warning: #D97706;
    --ember: #F45B69;
    --blaze: #DC2626;
    --gold: #B8942E;
    --glyph-bg-color: #EDEAE1;
    --glyph-path-fill: #16140F;
    --glyph-emerald-bg: #D1FAE5;
    --glyph-gold-bg: #FEF3C7;
    --glow-opacity: 0.12;
  }
}

html[data-theme="light"] {
  --bg-page: #F6F4EF;
  --bg-card: rgba(255, 254, 251, 0.88);
  --bg-elevated: #EDEAE1;
  --bg-code: #EAE6DB;
  --border: rgba(22, 20, 15, 0.12);
  --border-subtle: rgba(22, 20, 15, 0.08);
  --border-focus: #D97706;
  --border-ember: rgba(244, 91, 105, 0.35);
  --text-bright: #16140F;
  --text-primary: #2C2820;
  --text-secondary: #5E584D;
  --text-muted: #8E8678;
  --success: #0D9488;
  --warning: #D97706;
  --ember: #F45B69;
  --blaze: #DC2626;
  --gold: #B8942E;
  --glyph-bg-color: #EDEAE1;
  --glyph-path-fill: #16140F;
  --glyph-emerald-bg: #D1FAE5;
  --glyph-gold-bg: #FEF3C7;
  --glow-opacity: 0.12;
}

html[data-theme="dark"] {
  --bg-page: #0E0D0B;
  --bg-card: rgba(23, 21, 16, 0.82);
  --bg-elevated: #201E18;
  --bg-code: #080706;
  --border: #302C22;
  --border-subtle: #1E1C16;
  --border-focus: #FFA800;
  --border-ember: rgba(250, 80, 83, 0.45);
  --text-bright: #FFFFFF;
  --text-primary: #F0EBE2;
  --text-secondary: #9A9088;
  --text-muted: #7A7268;
  --success: #38D898;
  --warning: #FFA800;
  --ember: #FA5053;
  --blaze: #E86100;
  --gold: #D4AA3C;
  --glyph-bg-color: #1C1814;
  --glyph-path-fill: #F0EBE2;
  --glyph-emerald-bg: #103628;
  --glyph-gold-bg: #2E2010;
  --glow-opacity: 0.35;
}

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: var(--font-display);
  background-color: var(--bg-page);
  color: var(--text-primary);
  line-height: 1.5;
  min-height: 100vh;
  position: relative;
  overflow-x: hidden;
  -webkit-font-smoothing: antialiased;
  transition: background-color 0.3s ease, color 0.3s ease;
}

/* Ambient bottom glow */
body::before {
  content: "";
  position: fixed;
  inset: auto -10% -25% -10%;
  height: 55vh;
  background: radial-gradient(ellipse at bottom, rgba(232, 97, 0, var(--glow-opacity)) 0%, transparent 70%);
  filter: blur(80px);
  pointer-events: none;
  z-index: 0;
}

/* Token Ember Swarm Canvas */
#bgCanvas {
  position: fixed;
  top: 0;
  left: 0;
  width: 100vw;
  height: 100vh;
  z-index: 1;
  pointer-events: none;
}

.app-container {
  width: 100%;
  max-width: 1200px;
  margin: 0 auto;
  padding: 2rem 1.5rem 5rem;
  position: relative;
  z-index: 10;
}

/* Glass Card */
.glass-card {
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur);
  -webkit-backdrop-filter: var(--glass-blur);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
  transition: all 0.25s cubic-bezier(0.16, 1, 0.3, 1);
}

/* Top App Header */
.main-header {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 1.25rem;
  padding: 1.25rem 1.75rem;
  margin-bottom: 1.5rem;
}

.brand-section {
  display: flex;
  align-items: center;
  gap: 1.15rem;
}

.brand-logo-svg {
  width: 48px;
  height: 48px;
  filter: drop-shadow(0 0 16px rgba(232, 97, 0, 0.45));
}

.brand-title {
  font-size: 1.45rem;
  font-weight: 800;
  letter-spacing: -0.03em;
  color: var(--text-bright);
  display: flex;
  align-items: center;
  gap: 0.65rem;
}

.brand-badge {
  font-size: 0.72rem;
  font-family: var(--font-mono);
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  padding: 0.2rem 0.6rem;
  border-radius: 9999px;
  background: rgba(212, 170, 60, 0.15);
  border: 1px solid var(--gold);
  color: var(--gold);
}

.brand-sub {
  font-size: 0.85rem;
  color: var(--text-secondary);
  margin-top: 0.15rem;
}

.header-right {
  display: flex;
  align-items: center;
  gap: 0.85rem;
}

/* Theme Switcher */
.theme-switcher {
  display: flex;
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  padding: 2px;
  gap: 2px;
}

.theme-btn {
  background: transparent;
  border: none;
  color: var(--text-secondary);
  font-family: var(--font-mono);
  font-size: 0.75rem;
  font-weight: 600;
  padding: 0.3rem 0.6rem;
  border-radius: 4px;
  cursor: pointer;
  transition: all 0.15s;
}

.theme-btn.active {
  background: var(--bg-card);
  color: var(--text-bright);
  box-shadow: 0 1px 4px rgba(0,0,0,0.15);
}

.status-beacon {
  display: flex;
  align-items: center;
  gap: 0.55rem;
  background: rgba(56, 216, 152, 0.12);
  border: 1px solid rgba(56, 216, 152, 0.35);
  padding: 0.45rem 0.95rem;
  border-radius: 9999px;
  font-size: 0.82rem;
  font-weight: 700;
  color: var(--success);
  font-family: var(--font-mono);
}

.beacon-pulse {
  width: 8px;
  height: 8px;
  background: var(--success);
  border-radius: 50%;
  box-shadow: 0 0 12px var(--success);
  animation: pulse-beacon 2s infinite ease-in-out;
}

@keyframes pulse-beacon {
  0%, 100% { opacity: 1; transform: scale(1); }
  50% { opacity: 0.35; transform: scale(0.85); }
}

/* Morph Swarm Control Bar */
.swarm-morph-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.75rem;
  padding: 0.75rem 1.25rem;
  margin-bottom: 1.5rem;
}

.morph-label {
  font-size: 0.78rem;
  font-family: var(--font-mono);
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.1em;
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.morph-buttons {
  display: flex;
  gap: 0.4rem;
}

.morph-btn {
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  color: var(--text-secondary);
  font-family: var(--font-mono);
  font-size: 0.75rem;
  font-weight: 600;
  padding: 0.3rem 0.75rem;
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition: all 0.15s;
}

.morph-btn:hover, .morph-btn.active {
  color: var(--text-bright);
  border-color: var(--warning);
  background: rgba(255, 168, 0, 0.12);
}

/* Quick Connection Matrix */
.connection-matrix {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
  gap: 1rem;
  margin-bottom: 2.25rem;
}

.matrix-card {
  padding: 1rem 1.25rem;
}

.matrix-card:hover {
  border-color: var(--border-ember);
  transform: translateY(-2px);
  box-shadow: 0 12px 30px rgba(0, 0, 0, 0.2);
}

.matrix-title {
  font-size: 0.72rem;
  font-family: var(--font-mono);
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
  margin-bottom: 0.45rem;
}

.matrix-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
}

.matrix-row code {
  font-family: var(--font-mono);
  font-size: 0.85rem;
  color: var(--warning);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.matrix-btn {
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  color: var(--text-secondary);
  font-family: var(--font-mono);
  font-size: 0.75rem;
  font-weight: 600;
  padding: 0.22rem 0.6rem;
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition: all 0.15s;
  flex-shrink: 0;
}

.matrix-btn:hover {
  background: var(--border);
  color: var(--text-bright);
  border-color: var(--warning);
}

/* Section Header */
.section-top {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  margin-bottom: 1.25rem;
  padding-bottom: 0.5rem;
  border-bottom: 1px solid var(--border-subtle);
}

.section-h2 {
  font-size: 1.2rem;
  font-weight: 800;
  letter-spacing: -0.02em;
  color: var(--text-bright);
}

.section-sub {
  font-size: 0.82rem;
  color: var(--text-muted);
  font-family: var(--font-mono);
}

/* Client Tiles Grid */
.clients-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(340px, 1fr));
  gap: 1.35rem;
}

.client-tile {
  padding: 1.35rem;
  display: flex;
  flex-direction: column;
}

.client-tile:hover {
  border-color: var(--border-ember);
  box-shadow: 0 12px 35px rgba(0, 0, 0, 0.25);
}

.tile-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 0.6rem;
}

.glyph-and-title {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}

.glyph-frame {
  width: 44px;
  height: 44px;
  border-radius: 12px;
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  overflow: hidden;
  box-shadow: 0 4px 14px rgba(0, 0, 0, 0.15);
  padding: 5px;
}

.client-glyph-img {
  width: 100%;
  height: 100%;
  object-fit: contain;
  display: block;
}

.client-glyph-fallback {
  font-family: var(--font-mono);
  font-size: 1.1rem;
  font-weight: 700;
  color: var(--text-bright);
}

.tile-heading {
  font-size: 1rem;
  font-weight: 700;
  color: var(--text-bright);
}

.tile-id {
  font-size: 0.72rem;
  font-family: var(--font-mono);
  color: var(--text-muted);
}

.tile-caveat {
  font-size: 0.82rem;
  color: var(--text-secondary);
  margin-bottom: 0.9rem;
  line-height: 1.45;
}

.code-box {
  background: var(--bg-code);
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius-md);
  padding: 0.9rem 1.1rem;
  margin-bottom: 0.9rem;
  flex-grow: 1;
  overflow-x: auto;
}

pre code {
  font-family: var(--font-mono);
  font-size: 0.8rem;
  line-height: 1.48;
  color: var(--text-primary);
}

.wire-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.76rem;
}

.wire-tag {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-weight: 600;
}

.wire-code-pill {
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  color: var(--warning);
  padding: 0.25rem 0.6rem;
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition: all 0.15s;
  text-align: left;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.wire-code-pill:hover {
  border-color: var(--warning);
  background: var(--border);
}

.copy-action-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  color: var(--text-secondary);
  font-family: var(--font-mono);
  font-size: 0.76rem;
  font-weight: 600;
  padding: 0.35rem 0.75rem;
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition: all 0.15s ease;
}

.copy-action-btn:hover {
  background: var(--border);
  color: var(--text-bright);
  border-color: var(--border-ember);
}

.copy-action-btn:focus-visible, .wire-code-pill:focus-visible, .matrix-btn:focus-visible, .morph-btn:focus-visible, .theme-btn:focus-visible {
  outline: 2px solid var(--border-focus);
  outline-offset: 2px;
}

/* Toast */
#toast {
  position: fixed;
  bottom: 2rem;
  right: 2rem;
  background: linear-gradient(135deg, var(--ember) 0%, var(--warning) 100%);
  color: #fff;
  padding: 0.7rem 1.35rem;
  border-radius: 9999px;
  font-weight: 700;
  font-size: 0.86rem;
  font-family: var(--font-mono);
  box-shadow: 0 8px 30px rgba(250, 80, 83, 0.45);
  opacity: 0;
  transform: translateY(14px);
  transition: all 0.25s cubic-bezier(0.16, 1, 0.3, 1);
  pointer-events: none;
  z-index: 1000;
}

#toast.show {
  opacity: 1;
  transform: translateY(0);
}

@media (prefers-reduced-motion: reduce) {
  *, ::before, ::after {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}
/* Agent Instructions Button */
.agent-instructions-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  color: var(--text-bright);
  font-family: var(--font-mono);
  font-size: 0.78rem;
  font-weight: 700;
  padding: 0.42rem 0.85rem;
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition: all 0.15s ease;
}

.agent-instructions-btn:hover {
  background: var(--border);
  border-color: var(--warning);
  color: var(--warning);
  transform: translateY(-1px);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.2);
}

.agent-instructions-btn .robot-icon {
  stroke: var(--warning);
}

/* Modal Dialog */
.modal-backdrop {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.75);
  backdrop-filter: blur(12px);
  -webkit-backdrop-filter: blur(12px);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1.5rem;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.2s cubic-bezier(0.16, 1, 0.3, 1);
  z-index: 2000;
}

.modal-backdrop.open {
  opacity: 1;
  pointer-events: auto;
}

.modal-window {
  width: 100%;
  max-width: 640px;
  padding: 1.75rem;
  border: 1px solid var(--border-ember);
  box-shadow: 0 24px 60px rgba(0, 0, 0, 0.5);
  transform: scale(0.96) translateY(8px);
  transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1);
}

.modal-backdrop.open .modal-window {
  transform: scale(1) translateY(0);
}

.modal-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 1.25rem;
}

.modal-title-group {
  display: flex;
  align-items: center;
  gap: 0.85rem;
}

.modal-icon-badge {
  width: 44px;
  height: 44px;
  border-radius: 12px;
  background: rgba(255, 168, 0, 0.12);
  border: 1px solid var(--warning);
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.modal-icon-badge .robot-icon {
  stroke: var(--warning);
}

.modal-heading {
  font-size: 1.15rem;
  font-weight: 800;
  color: var(--text-bright);
}

.modal-sub {
  font-size: 0.82rem;
  color: var(--text-secondary);
  margin-top: 0.15rem;
}

.modal-close-btn {
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  color: var(--text-muted);
  width: 32px;
  height: 32px;
  border-radius: var(--radius-sm);
  display: grid;
  place-items: center;
  cursor: pointer;
  transition: all 0.15s;
  font-size: 0.9rem;
}

.modal-close-btn:hover {
  background: var(--border);
  color: var(--text-bright);
  border-color: var(--ember);
}

.modal-code-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 0.5rem;
}

.code-badge {
  font-size: 0.72rem;
  font-family: var(--font-mono);
  font-weight: 700;
  letter-spacing: 0.08em;
  color: var(--text-muted);
}

.modal-code-box {
  max-height: 280px;
  overflow-y: auto;
}

.modal-code-box pre code {
  white-space: pre-wrap;
  word-break: break-word;
}
</style>
</head>
<body>

<canvas id="bgCanvas" aria-hidden="true"></canvas>

<div class="app-container">
  <header class="glass-card main-header">
    <div class="brand-section">
      <svg class="brand-logo-svg" viewBox="0 0 256 256" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="m219.4 165.8c0-21.55-6.09-42.7-16.19-59.49-2.04-3.41-6.29-1.8-6.69 2.14-1.54 11.73-4.28 20.86-14.29 30.79-1.3 1.29-2.17 2.08-0.96 4.08 1.07 1.85 4.11 1.49 6.21 1.41 3.37-0.13 4.7 1.8 4.7 4.8v76.33c15.87-15.69 27.22-35.75 27.22-60.06z" fill="url(#p0)"/>
        <path d="m183.6 150.6h-21.89c-2.15 0-3.89 0.97-3.89 3.57v92.2c10.94-4.19 20.1-9.63 27.85-15.75v-76.3c0-2.04-0.85-3.72-2.07-3.72z" fill="url(#p1)"/>
        <path d="m148.8 176.9h-21.01c-2.06 0-2.9 1.26-2.9 2.98v72.1c10.37-0.36 19.37-2.07 26.57-3.99v-68.16c0-1.67-1.27-2.93-2.66-2.93z" fill="url(#p2)"/>
        <path d="m116.2 195.9c-0.69-0.73-1.51-0.66-1.84-0.66h-20.24c-2.11 0-2.79 1.59-2.79 3.03v49.68c9.02 2.79 17.47 4.02 27.17 4.02v-53.62c0-0.63-0.55-2.02-2.3-2.45z" fill="url(#p3)"/>
        <path d="m82.41 216.6h-20.89c-1.61 0-2.91 1.17-2.91 2.89v10.4c8.19 7.67 17.28 13.09 26.13 16.29v-26.69c0-1.64-0.9-2.89-2.33-2.89z" fill="url(#p4)"/>
        <path d="m171.6 4.7c-1.76-1.09-3.67-0.59-4.86 0.45-22.97 19.26-45.45 45.79-53.94 93.11-2.72-10.13-5.91-14.48-12.12-21.43-3.3-2.68-6.7-0.6-5.98 2.8 7.11 15.71 2.97 29.15-14.11 45.44-0.98-5.2-0.96-10.96-0.31-17.18 0.47-2.92-3.2-4.55-5.22-2.08-19 21.58-39.35 47.26-39.35 77.2 0 14.8 6.29 29.97 16.59 41.19v-10.57c0-3.25 1.91-4.06 4.55-4.02h25.35c-11.5-17.34-4.46-38.39 21.13-64.72-1.17 5.44-2.31 19 9.2 23.86 15.15 5.05 43.43-12.47 54.79-35.59 9.39-22.1-3.56-39.03-8.41-61.05-5.01-22.73 0.3-43.3 12.97-64.04 1.54-2.2 0.43-2.93-0.28-3.37z" fill="url(#p5)"/>
        <path d="m166.3 5.83c-14.59 12.24-34.96 35.89-42.37 73.87-3.09 15.13-3.55 37.15-24.66 55.28-11.88 9.28-19.63 9.14-23.24 8.03-9.82-3.1-10.35-15.14-2.36-30.09-13.74 15.26-30.5 37.84-25.93 69.99 0.79 5.76 1.74 9.02 1.74 9.02 4.76-20.73 23.46-30.79 37.96-42.32 20.2-14.5 33.51-32.46 36.2-61.5 3.3-29.03 13.97-51.05 42.66-82.28z" fill="url(#p6)"/>
        <path d="m73.64 112.9c-13.46 14.27-14.76 33.74-2.65 38.15-10.81 2.96-17.48 15.31-21.82 26.75-4.25-10.94-3.14-30.51 24.47-64.9z" fill="url(#p7)"/>
        <path d="m167.2 4.7c-16.79 12.71-31.4 40.29-28.27 73.41 1.19 13.03 5.97 27.04 3.11 41.98-4.56 22.19-21.12 35.72-31.54 39.31-4.07-3.64-6.72-7.92-6.72-14.96-1.08 3.24-3.28 14.68 5.28 22.44 12 7.77 38.91-5.09 54.81-28.78 11.93-19.92 5.03-35.31-0.86-53.39-9.91-27.78-5.91-49.51 8.39-75.96 1.78-2.82 0.8-5.11-4.2-4.05z" fill="url(#p8)"/>
        <defs>
          <linearGradient id="p0" x1="182.1" x2="227.7" y1="110.1" y2="199.8" gradientUnits="userSpaceOnUse"><stop stop-color="#E31B24"/><stop stop-color="#B01127" offset="1"/></linearGradient>
          <linearGradient id="p1" x1="158.4" x2="201.6" y1="155.9" y2="231.4" gradientUnits="userSpaceOnUse"><stop stop-color="#E31B24"/><stop stop-color="#B01127" offset="1"/></linearGradient>
          <linearGradient id="p2" x1="123.1" x2="161.2" y1="179.2" y2="248" gradientUnits="userSpaceOnUse"><stop stop-color="#E74C16"/><stop stop-color="#E04016" offset="1"/></linearGradient>
          <linearGradient id="p3" x1="89.8" x2="123.1" y1="198.1" y2="249.8" gradientUnits="userSpaceOnUse"><stop stop-color="#F4831F"/><stop stop-color="#F0671A" offset="1"/></linearGradient>
          <linearGradient id="p4" x1="56.65" x2="81.01" y1="217.8" y2="250.4" gradientUnits="userSpaceOnUse"><stop stop-color="#FCC827"/><stop stop-color="#FEA41C" offset="1"/></linearGradient>
          <linearGradient id="p5" x1="105.8" x2="105.8" y1="4" y2="224.2" gradientUnits="userSpaceOnUse"><stop stop-color="#FDBA12"/><stop stop-color="#F66005" offset=".4844"/><stop stop-color="#F25205" offset="1"/></linearGradient>
          <linearGradient id="p6" x1="105.8" x2="105.8" y1="5.828" y2="191.9" gradientUnits="userSpaceOnUse"><stop stop-color="#FED430"/><stop stop-color="#FEA41C" offset=".5052"/><stop stop-color="#FE9111" offset="1"/></linearGradient>
          <linearGradient id="p7" x1="61.22" x2="61.22" y1="112.9" y2="177.8" gradientUnits="userSpaceOnUse"><stop stop-color="#FEA21C"/><stop stop-color="#FEA21C" stop-opacity=".25" offset="1"/></linearGradient>
          <linearGradient id="p8" x1="138.6" x2="138.6" y1="4.441" y2="169.7" gradientUnits="userSpaceOnUse"><stop stop-color="#FEA41C"/><stop stop-color="#F76D05" offset=".4896"/><stop stop-color="#E60000" offset=".9635"/></linearGradient>
        </defs>
      </svg>
      <div>
        <h1 class="brand-title">OpenBurnBar Gateway <span class="brand-badge">Loopback</span></h1>
        <p class="brand-sub">Standalone loopback relay on port :${port}. Zero quota overhead.</p>
      </div>
    </div>
    <div class="header-right">
      <button class="agent-instructions-btn" onclick="toggleAgentModal(true)" aria-label="Instructions for Agents">
        <svg class="robot-icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <rect x="3" y="11" width="18" height="10" rx="2"></rect>
          <circle cx="12" cy="5" r="2"></circle>
          <path d="M12 7v4"></path>
          <line x1="8" y1="16" x2="8" y2="16"></line>
          <line x1="16" y1="16" x2="16" y2="16"></line>
        </svg>
        <span>Instructions for Agents</span>
      </button>
      <div class="theme-switcher" role="radiogroup" aria-label="Theme">
        <button class="theme-btn active" data-set-theme="system" onclick="setTheme('system')">Auto</button>
        <button class="theme-btn" data-set-theme="dark" onclick="setTheme('dark')">Dark</button>
        <button class="theme-btn" data-set-theme="light" onclick="setTheme('light')">Light</button>
      </div>
      <div class="status-beacon" role="status">
        <span class="beacon-pulse"></span>
        <span>ACTIVE :${port}</span>
      </div>
    </div>
  </header>

  <div class="glass-card swarm-morph-bar">
    <div class="morph-label">
      <span>✨ Token Ember Swarm</span>
    </div>
    <div class="morph-buttons">
      <button class="morph-btn active" onclick="setSwarmMode('swarm', this)">Swarm</button>
      <button class="morph-btn" onclick="setSwarmMode('shape-dollar', this)">$ Dollar</button>
      <button class="morph-btn" onclick="setSwarmMode('shape-code', this)">&lt;/&gt; Code</button>
      <button class="morph-btn" onclick="setSwarmMode('shape-rings', this)">◎ Orbits</button>
    </div>
  </div>

  <section class="connection-matrix" aria-label="Gateway endpoints and keys">
    <div class="glass-card matrix-card">
      <div class="matrix-title">OpenAI Base URL</div>
      <div class="matrix-row">
        <code>${openaiUrl}</code>
        <button class="matrix-btn" onclick="copySnippet('${openaiUrl}', this)">Copy</button>
      </div>
    </div>
    <div class="glass-card matrix-card">
      <div class="matrix-title">Anthropic Base URL</div>
      <div class="matrix-row">
        <code>${anthropicUrl}</code>
        <button class="matrix-btn" onclick="copySnippet('${anthropicUrl}', this)">Copy</button>
      </div>
    </div>
    <div class="glass-card matrix-card">
      <div class="matrix-title">Local Auth Key</div>
      <div class="matrix-row">
        <code>${localKeyText}</code>
        <button class="matrix-btn" onclick="copySnippet('${localKeyText}', this)">Copy</button>
      </div>
    </div>
    <div class="glass-card matrix-card">
      <div class="matrix-title">Stop Daemon</div>
      <div class="matrix-row">
        <code>openburnbar proxy stop --port ${port}</code>
        <button class="matrix-btn" onclick="copySnippet('openburnbar proxy stop --port ${port}', this)">Copy</button>
      </div>
    </div>
  </section>

  <div class="section-top">
    <h2 class="section-h2">Provider & Harness Configurations</h2>
    <span class="section-sub">1-Click Copy or CLI Auto-Wire</span>
  </div>

  <section class="clients-grid" aria-label="Agent Configuration Snippets">
    ${snippetCards}
  </section>
</div>

<div id="agentModal" class="modal-backdrop" onclick="if (event.target === this) toggleAgentModal(false)" aria-hidden="true" role="dialog" aria-labelledby="modalTitle">
  <div class="glass-card modal-window">
    <div class="modal-header">
      <div class="modal-title-group">
        <div class="modal-icon-badge">
          <svg class="robot-icon" viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="3" y="11" width="18" height="10" rx="2"></rect>
            <circle cx="12" cy="5" r="2"></circle>
            <path d="M12 7v4"></path>
            <line x1="8" y1="16" x2="8" y2="16"></line>
            <line x1="16" y1="16" x2="16" y2="16"></line>
          </svg>
        </div>
        <div>
          <h2 id="modalTitle" class="modal-heading">Instructions for Coding Agents</h2>
          <p class="modal-sub">Directive snippet for <code>AGENTS.md</code>, <code>CLAUDE.md</code>, or <code>.cursorrules</code></p>
        </div>
      </div>
      <button class="modal-close-btn" onclick="toggleAgentModal(false)" aria-label="Close modal">✕</button>
    </div>

    <div class="modal-body">
      <div class="modal-code-header">
        <span class="code-badge">MARKDOWN PROMPT SNIPPET</span>
        <button class="copy-action-btn" onclick="copyAgentInstructions(this)">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
          <span>Copy Directive</span>
        </button>
      </div>
      <div class="code-box modal-code-box">
        <pre><code id="agentDirectiveCode">## OpenBurnBar Gateway Configuration for Coding Agents

This system runs OpenBurnBar Gateway locally on port :${port} (loopback relay).
Use this endpoint for local OpenAI / Anthropic proxying with zero quota overhead:

- OpenAI Base URL: http://127.0.0.1:${port}/v1
- Anthropic Base URL: http://127.0.0.1:${port} (Messages API)
- Auth Header / Key: Bearer ${localKeyText}
- Available Models: grok-4.6, grok-composer-2.5-fast, gpt-5.6-luna, claude-opus-5, claude-sonnet-4-6
- CLI Auto-Wire:
  - Claude Code: openburnbar proxy wire claude --write
  - Droid: openburnbar proxy wire droid --write
  - Grok CLI: openburnbar proxy wire grok --write
  - Codex CLI: openburnbar proxy wire codex --write
  - OpenCode: openburnbar proxy wire opencode --write
- Rules: Always connect via 127.0.0.1 (IPv4 loopback only). Never leak private upstream keys.</code></pre>
      </div>
    </div>
  </div>
</div>

<div id="toast" role="alert" aria-live="assertive">Copied to clipboard! ✓</div>

<script>
// Agent Modal Control
function toggleAgentModal(open) {
  const modal = document.getElementById('agentModal');
  if (!modal) return;
  modal.classList.toggle('open', open);
  modal.setAttribute('aria-hidden', (!open).toString());
}

function copyAgentInstructions(btn) {
  const el = document.getElementById('agentDirectiveCode');
  if (el) copySnippet(el.textContent.trim(), btn);
}

window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') toggleAgentModal(false);
});

// Theme Management
function setTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  localStorage.setItem('burnbar-theme', theme);
  document.querySelectorAll('.theme-btn').forEach(btn => {
    btn.classList.toggle('active', btn.getAttribute('data-set-theme') === theme);
  });
  if (window.updateSwarmPalette) window.updateSwarmPalette();
}

(function initTheme() {
  const saved = localStorage.getItem('burnbar-theme') || 'system';
  setTheme(saved);
})();

// Token Ember Swarm Engine
(function initSwarm() {
  const canvas = document.getElementById('bgCanvas');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');

  let width = canvas.width = window.innerWidth;
  let height = canvas.height = window.innerHeight;

  window.addEventListener('resize', () => {
    width = canvas.width = window.innerWidth;
    height = canvas.height = window.innerHeight;
  });

  const offscreen = document.createElement('canvas');
  const oCtx = offscreen.getContext('2d');

  function samplePointsFromText(text, size = 260) {
    offscreen.width = 400;
    offscreen.height = 400;
    oCtx.fillStyle = '#000';
    oCtx.fillRect(0, 0, 400, 400);
    oCtx.fillStyle = '#fff';
    oCtx.font = "800 " + size + "px monospace";
    oCtx.textAlign = 'center';
    oCtx.textBaseline = 'middle';
    oCtx.fillText(text, 200, 200);

    const imgData = oCtx.getImageData(0, 0, 400, 400).data;
    const pts = [];
    const gap = 7;
    for (let y = 0; y < 400; y += gap) {
      for (let x = 0; x < 400; x += gap) {
        const idx = (y * 400 + x) * 4;
        if (imgData[idx] > 128) {
          pts.push({ x: (x - 200) / 200, y: (y - 200) / 200 });
        }
      }
    }
    return pts;
  }

  function generateRingPoints() {
    const pts = [];
    for (let ring = 0; ring < 3; ring++) {
      const radius = 0.22 + (ring * 0.24);
      const numPts = 60 + ring * 40;
      for (let i = 0; i < numPts; i++) {
        const angle = (i / numPts) * Math.PI * 2;
        pts.push({ x: Math.cos(angle) * radius, y: Math.sin(angle) * radius });
      }
    }
    return pts;
  }

  const shapes = {
    'swarm': [],
    'shape-dollar': samplePointsFromText('$'),
    'shape-code': samplePointsFromText('</>', 200),
    'shape-rings': generateRingPoints()
  };

  const PARTICLE_COUNT = Math.min(650, Math.floor((width * height) / 2500));
  const GLYPHS = ['$', '{}', '</>', 'tok', 'ctx', '429', '503', 'gpt-5', 'claude-opus', 'run'];
  
  function getPalette() {
    const isLight = document.documentElement.getAttribute('data-theme') === 'light' ||
      (document.documentElement.getAttribute('data-theme') === 'system' && window.matchMedia('(prefers-color-scheme: light)').matches);
    if (isLight) {
      return ['#F45B69', '#D97706', '#0D9488', '#B8942E', '#4B5563'];
    }
    return ['#FA5053', '#FFA800', '#F4831F', '#FDBA12', '#E86100'];
  }

  let currentColors = getPalette();
  window.updateSwarmPalette = function() {
    currentColors = getPalette();
    particles.forEach(p => p.color = currentColors[Math.floor(Math.random() * currentColors.length)]);
  };

  const pointer = { x: -1000, y: -1000, active: false };
  window.addEventListener('mousemove', (e) => {
    pointer.x = e.clientX;
    pointer.y = e.clientY;
    pointer.active = true;
  });
  window.addEventListener('mouseleave', () => pointer.active = false);

  let currentMode = 'swarm';
  window.setSwarmMode = function(mode, btn) {
    currentMode = mode;
    document.querySelectorAll('.morph-btn').forEach(b => b.classList.remove('active'));
    if (btn) btn.classList.add('active');

    const shapePts = shapes[mode] || [];
    const centerX = width / 2;
    const centerY = height / 2;
    const scale = Math.min(width, height) * 0.38;

    particles.forEach((p, idx) => {
      if (mode === 'swarm' || shapePts.length === 0) {
        p.tx = null;
        p.ty = null;
      } else {
        const pt = shapePts[idx % shapePts.length];
        p.tx = centerX + pt.x * scale;
        p.ty = centerY + pt.y * scale;
      }
    });
  };

  class EmberParticle {
    constructor() {
      this.x = Math.random() * width;
      this.y = Math.random() * height;
      this.vx = (Math.random() - 0.5) * 1.2;
      this.vy = (Math.random() - 0.5) * 1.2;
      this.size = 1 + Math.random() * 1.8;
      this.isGlyph = Math.random() < 0.08;
      this.text = GLYPHS[Math.floor(Math.random() * GLYPHS.length)];
      this.color = currentColors[Math.floor(Math.random() * currentColors.length)];
      this.tx = null;
      this.ty = null;
      this.baseAlpha = 0.15 + Math.random() * 0.45;
      this.twinkle = Math.random() * Math.PI * 2;
    }

    update() {
      this.twinkle += 0.03;
      if (currentMode === 'swarm' || this.tx === null) {
        this.vx += (Math.random() - 0.5) * 0.1;
        this.vy += (Math.random() - 0.5) * 0.1;
        this.vx *= 0.98;
        this.vy *= 0.98;

        if (pointer.active) {
          const dx = this.x - pointer.x;
          const dy = this.y - pointer.y;
          const dist = Math.sqrt(dx * dx + dy * dy);
          if (dist < 140 && dist > 0) {
            const force = (140 - dist) / 140;
            this.vx += (dx / dist) * force * 1.5;
            this.vy += (dy / dist) * force * 1.5;
          }
        }

        this.x += this.vx;
        this.y += this.vy;

        if (this.x < -10) this.x = width + 10;
        if (this.x > width + 10) this.x = -10;
        if (this.y < -10) this.y = height + 10;
        if (this.y > height + 10) this.y = -10;
      } else {
        const dx = this.tx - this.x;
        const dy = this.ty - this.y;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist > 1) {
          this.vx += (dx / dist) * 0.5;
          this.vy += (dy / dist) * 0.5;
        }
        this.vx *= 0.85;
        this.vy *= 0.85;
        this.x += this.vx;
        this.y += this.vy;
      }
    }

    draw() {
      const alpha = Math.max(0.1, this.baseAlpha + Math.sin(this.twinkle) * 0.2);
      ctx.globalAlpha = alpha;
      if (this.isGlyph && currentMode === 'swarm') {
        ctx.font = "600 10px monospace";
        ctx.fillStyle = this.color;
        ctx.fillText(this.text, this.x, this.y);
      } else {
        ctx.beginPath();
        ctx.arc(this.x, this.y, this.size, 0, Math.PI * 2);
        ctx.fillStyle = this.color;
        ctx.fill();
      }
    }
  }

  const particles = [];
  for (let i = 0; i < PARTICLE_COUNT; i++) {
    particles.push(new EmberParticle());
  }

  function loop() {
    ctx.clearRect(0, 0, width, height);

    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      p.update();
      p.draw();

      if (currentMode === 'swarm') {
        for (let j = i + 1; j < Math.min(i + 8, particles.length); j++) {
          const p2 = particles[j];
          const dx = p.x - p2.x;
          const dy = p.y - p2.y;
          const dist = Math.sqrt(dx * dx + dy * dy);
          if (dist < 70) {
            ctx.beginPath();
            ctx.moveTo(p.x, p.y);
            ctx.lineTo(p2.x, p2.y);
            ctx.strokeStyle = currentColors[1] || '#FFA800';
            ctx.globalAlpha = (1 - dist / 70) * 0.12;
            ctx.lineWidth = 0.7;
            ctx.stroke();
          }
        }
      }
    }

    ctx.globalAlpha = 1;
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
})();

function showToast(msg) {
  const t = document.getElementById('toast');
  if (!t) return;
  t.textContent = msg || 'Copied to clipboard! ✓';
  t.classList.add('show');
  clearTimeout(window.__tt);
  window.__tt = setTimeout(() => t.classList.remove('show'), 2000);
}

function copySnippet(text, btn) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(() => {
      showToast('Copied! ✓');
      if (btn) {
        const old = btn.textContent;
        btn.textContent = '✓ Copied';
        setTimeout(() => btn.textContent = old, 1800);
      }
    }).catch(() => fallbackCopy(text));
  } else {
    fallbackCopy(text);
  }
}

function copySnippetText(btn) {
  const card = btn.closest('.client-tile');
  if (!card) return;
  const code = card.querySelector('.raw-snippet');
  if (code) copySnippet(code.textContent.trim(), btn);
}

function fallbackCopy(text) {
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  try {
    document.execCommand('copy');
    showToast('Copied! ✓');
  } catch (e) {
    showToast('Failed to copy');
  }
  document.body.removeChild(ta);
}
</script>
</body>
</html>
`;
}

export function defaultPanelOpener(platform: NodeJS.Platform, url: string): Promise<void> {
  const command = platform === "win32" ? "cmd" : platform === "darwin" ? "open" : "xdg-open";
  const args = platform === "win32" ? ["/c", "start", "", url] : [url];
  return new Promise((resolve, reject) => {
    execFile(command, args, { timeout: 5_000 }, (error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

export async function openLoopbackPanel(
  port: number,
  options: {
    platform?: NodeJS.Platform;
    opener?: (url: string) => Promise<void>;
    log?: (message: string) => void;
  } = {}
): Promise<void> {
  const url = gatewayPanelUrl(port);
  const log = options.log ?? ((message: string) => process.stdout.write(message));
  log(`Gateway panel: ${url}\n`);
  const opener = options.opener ?? ((target) => defaultPanelOpener(options.platform ?? process.platform, target));
  try {
    await opener(url);
  } catch (error) {
    log(
      `Could not open a browser (${error instanceof Error ? error.message : String(error)}). Open ${url} yourself.\n`
    );
  }
}
