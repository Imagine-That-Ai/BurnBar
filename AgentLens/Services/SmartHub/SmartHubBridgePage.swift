import Foundation

// MARK: - Smart Hub Bridge — Static Page
//
// The HTML the Nest Hub renders. Polls /state.json every 5s and re-renders
// when the server-bumped `version` increments. Designed for the 10"
// Nest Hub Max (1024×600) and 7" Nest Hub (1024×600 effective): horizontal
// row of glass provider cards, each showing token total, multi-bucket
// usage bars, account chips, and a runs+spend footer.
//
// The dashboard is data-driven: each card is built from the JSON the
// bridge emits in `SmartHubBridgeServer.providerJSON(_:)`. New providers
// drop in automatically without HTML edits as long as their card payload
// follows the same shape.

enum SmartHubBridgePage {

    static let html: String = ##"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
      <title>OpenBurnBar — Quota</title>
      <style>
        :root {
          color-scheme: dark;
          --bg-1: #0E0D0B;
          --bg-2: #171510;
          --bg-top: #1B1610;
          --bg-bottom: #07060A;
          --ember: #E07868;
          --whimsy: #A294F0;
          --amber: #E5A848;
          --mercury: #C8BFB5;
          --success: #38D898;
          --warning: #F0C040;
          --text-1: #F0EBE2;
          --text-2: #9A9088;
          --text-3: #7A7268;
          --border: #302C22;
          --border-strong: #3F3A2E;
          --primary: var(--ember);
          --secondary: var(--whimsy);
          --rainbow-gradient: linear-gradient(90deg,
            #E40303 0%, #FF8C00 17%, #FFED00 33%,
            #008026 50%, #004CFF 67%, #732982 100%);
          --dashboard-brightness: 1.0;
        }
        * { box-sizing: border-box; }
        html, body {
          margin: 0; padding: 0; height: 100%;
          background:
            radial-gradient(900px 600px at 20% 10%, rgba(95,79,210,0.18) 0%, transparent 60%),
            radial-gradient(700px 500px at 90% 80%, rgba(224,120,104,0.10) 0%, transparent 55%),
            linear-gradient(180deg, var(--bg-top) 0%, var(--bg-bottom) 100%);
          font-family: -apple-system, "SF Pro Rounded", "SF Pro", system-ui, sans-serif;
          color: var(--text-1);
          overflow: hidden;
          filter: brightness(var(--dashboard-brightness));
          transition: filter 0.35s ease;
        }

        /* Layered grid pattern overlay — the faint dots in the mock. */
        body::before {
          content: '';
          position: fixed; inset: 0;
          background-image:
            linear-gradient(rgba(255,255,255,0.025) 1px, transparent 1px),
            linear-gradient(90deg, rgba(255,255,255,0.025) 1px, transparent 1px);
          background-size: 28px 28px;
          pointer-events: none;
          z-index: 0;
        }

        .stage {
          display: grid;
          grid-template-rows: auto auto 1fr auto;
          gap: 14px;
          height: 100vh;
          padding: 18px 22px 16px;
          position: relative;
          z-index: 1;
        }

        /* TOP HEADER ROW — logo + status pill, refresh, day/time */
        header.topbar {
          display: grid;
          grid-template-columns: 1fr auto 1fr;
          align-items: center;
          gap: 14px;
        }
        .brand-row {
          display: flex; align-items: center; gap: 10px;
          color: var(--text-2);
          font-size: 13px;
          font-weight: 500;
        }
        .brand-logo {
          width: 28px; height: 28px;
          display: block;
          flex: 0 0 28px;
          object-fit: contain;
          filter: drop-shadow(0 0 8px color-mix(in oklab, var(--primary) 38%, transparent));
        }
        .live-dot {
          width: 8px; height: 8px; border-radius: 50%;
          background: var(--success);
          box-shadow: 0 0 0 4px rgba(56,216,152,0.12);
        }
        .day-time {
          text-align: right;
          font-size: 13px;
          font-weight: 500;
          color: var(--text-2);
          line-height: 1.25;
          font-variant-numeric: tabular-nums;
        }
        .day-time .clock {
          color: var(--text-1);
          font-weight: 600;
        }

        /* PERIOD + REFRESH BAR */
        .controls {
          display: flex;
          align-items: center;
          justify-content: center;
          gap: 14px;
        }
        .segmented {
          display: inline-flex;
          background: rgba(255,255,255,0.04);
          border: 1px solid var(--border);
          border-radius: 999px;
          padding: 4px;
        }
        .segmented button {
          appearance: none;
          background: transparent;
          color: var(--text-2);
          border: 0;
          font-size: 13px;
          font-weight: 600;
          padding: 7px 14px;
          min-width: 48px;
          border-radius: 999px;
          cursor: pointer;
          font-family: inherit;
          transition: background 0.18s ease, color 0.18s ease;
        }
        .segmented button.active {
          background: rgba(255,255,255,0.10);
          color: var(--text-1);
          box-shadow: 0 1px 2px rgba(0,0,0,0.3);
        }
        .refresh-btn {
          appearance: none;
          background: rgba(255,255,255,0.04);
          color: var(--text-1);
          border: 1px solid var(--border);
          border-radius: 999px;
          padding: 8px 22px;
          font-size: 14px;
          font-weight: 600;
          cursor: pointer;
          font-family: inherit;
          display: inline-flex; align-items: center; gap: 8px;
          transition: background 0.18s ease, transform 0.18s ease;
        }
        .refresh-btn[disabled] { opacity: 0.55; cursor: progress; }
        .refresh-btn:hover:not([disabled]) { background: rgba(255,255,255,0.08); }
        .refresh-btn .spinner {
          width: 12px; height: 12px;
          border: 2px solid rgba(232,219,210,0.2);
          border-top-color: var(--mercury);
          border-radius: 50%;
          animation: spin 0.9s linear infinite;
          display: none;
        }
        .refresh-btn.refreshing .spinner { display: inline-block; }
        @keyframes spin { to { transform: rotate(360deg); } }

        /* PROVIDER CARDS — horizontal rail */
        .providers {
          display: flex;
          gap: 14px;
          align-items: stretch;
          overflow-x: auto;
          overflow-y: hidden;
          padding: 4px 2px 10px;
          scroll-snap-type: x mandatory;
          scrollbar-width: none;
        }
        .providers::-webkit-scrollbar { display: none; }
        .empty {
          align-self: center;
          margin: auto;
          text-align: center;
          color: var(--text-3);
          font-size: 16px;
        }

        .card {
          --card-accent: var(--primary);
          flex: 0 0 232px;
          min-width: 232px;
          max-width: 232px;
          background: linear-gradient(180deg,
            color-mix(in oklab, var(--card-accent) 16%, #16130F) 0%,
            color-mix(in oklab, var(--card-accent) 4%, #0F0D0A) 60%,
            #0B0908 100%);
          border: 1.5px solid color-mix(in oklab, var(--card-accent) 50%, transparent);
          border-radius: 18px;
          padding: 14px 14px 12px;
          display: grid;
          grid-template-rows: auto auto auto auto 1fr auto auto;
          gap: 8px;
          scroll-snap-align: start;
          position: relative;
          box-shadow:
            0 0 0 1px rgba(255,255,255,0.04) inset,
            0 14px 28px rgba(0,0,0,0.35),
            0 0 28px color-mix(in oklab, var(--card-accent) 25%, transparent);
        }
        .card .top {
          display: flex; align-items: flex-start; gap: 10px;
        }
        .card .logo {
          width: 32px; height: 32px;
          flex: 0 0 32px;
          border-radius: 8px;
          overflow: hidden;
          display: flex; align-items: center; justify-content: center;
        }
        .card .logo svg { width: 100%; height: 100%; display: block; }
        .card .top-text { flex: 1; min-width: 0; }
        .card .name {
          font-size: 22px;
          font-weight: 700;
          letter-spacing: -0.4px;
          color: var(--text-1);
          line-height: 1.1;
          margin-bottom: 2px;
        }
        .card .freshness {
          font-size: 11px;
          color: var(--text-2);
          line-height: 1.3;
          font-variant-numeric: tabular-nums;
        }
        .card .top-dot {
          width: 8px; height: 8px; border-radius: 50%;
          background: rgba(255,255,255,0.18);
          margin-top: 6px;
        }
        .card.live .top-dot { background: var(--success); box-shadow: 0 0 0 3px rgba(56,216,152,0.12); }

        .status-pill {
          display: inline-flex; align-items: center;
          align-self: start;
          background: rgba(255,255,255,0.06);
          color: var(--text-2);
          font-size: 11px;
          font-weight: 600;
          padding: 4px 10px;
          border-radius: 999px;
          letter-spacing: 0.2px;
          text-transform: lowercase;
        }
        .status-pill.tone-success { background: color-mix(in oklab, var(--success) 22%, transparent); color: var(--success); }
        .status-pill.tone-whimsy  { background: color-mix(in oklab, var(--whimsy) 22%, transparent);  color: var(--whimsy); }
        .status-pill.tone-ember   { background: color-mix(in oklab, var(--ember) 22%, transparent);   color: var(--ember); }
        .status-pill.tone-warning { background: color-mix(in oklab, var(--warning) 22%, transparent); color: var(--warning); }
        .status-pill.tone-mercury { background: rgba(232,219,210,0.10); color: var(--mercury); }

        .token-total {
          font-size: 54px;
          font-weight: 800;
          letter-spacing: -2px;
          color: var(--text-1);
          line-height: 1.0;
          margin-top: 2px;
        }
        .token-label {
          font-size: 11px;
          font-weight: 600;
          letter-spacing: 1.6px;
          color: var(--text-3);
          text-transform: uppercase;
          padding-bottom: 4px;
          border-bottom: 1px solid rgba(255,255,255,0.07);
        }

        .bucket-list {
          display: grid;
          gap: 8px;
          align-content: start;
          padding-top: 2px;
        }
        .bucket {
          display: grid;
          grid-template-columns: 1fr auto;
          row-gap: 4px;
          column-gap: 6px;
          align-items: baseline;
        }
        .bucket .name {
          font-size: 13px;
          font-weight: 500;
          color: var(--text-2);
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .bucket .value {
          font-size: 14px;
          font-weight: 700;
          color: var(--text-1);
          font-variant-numeric: tabular-nums;
        }
        .bucket .bar {
          grid-column: 1 / -1;
          position: relative;
          height: 5px;
          border-radius: 999px;
          background: rgba(255,255,255,0.07);
          overflow: hidden;
        }
        .bucket .fill {
          position: absolute; inset: 0; width: 0%;
          border-radius: 999px;
          background: var(--card-accent);
          transition: width 0.6s ease;
        }
        .bucket .fill.tone-success { background: var(--success); }
        .bucket .fill.tone-whimsy  { background: var(--whimsy); }
        .bucket .fill.tone-warning { background: var(--warning); }
        .bucket .fill.tone-mercury { background: var(--mercury); }
        .bucket .sub {
          grid-column: 1 / -1;
          font-size: 11px;
          color: var(--text-3);
          font-variant-numeric: tabular-nums;
        }
        /* Reset-time row — its own line, slightly louder than `.sub` so the
           5h / weekly refill moment reads from across the room. Tabular
           nums keep the "in Xh Ym · MMM d, h:mm a" string from twitching on
           every state.json poll. */
        .bucket .reset {
          grid-column: 1 / -1;
          font-size: 11px;
          font-weight: 600;
          letter-spacing: 0.2px;
          color: color-mix(in oklab, var(--card-accent) 78%, var(--text-2));
          font-variant-numeric: tabular-nums;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }

        /* Accounts block — compact rows inside provider cards */
        .accounts-block {
          display: grid;
          gap: 5px;
          align-content: start;
        }
        .accounts-block .header {
          display: flex;
          align-items: center;
          gap: 6px;
          font-size: 11px;
          font-weight: 600;
          letter-spacing: 0.3px;
          text-transform: uppercase;
          color: var(--text-3);
        }
        .accounts-block .count {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          min-width: 18px;
          height: 18px;
          padding: 0 5px;
          border-radius: 999px;
          background: var(--surface-elevated, rgba(255,255,255,0.06));
          color: var(--text-2);
          font-size: 10px;
          font-weight: 700;
          font-variant-numeric: tabular-nums;
        }
        .account {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 6px;
          min-width: 0;
        }
        .account .ident {
          display: flex;
          align-items: center;
          gap: 6px;
          min-width: 0;
          flex: 1;
        }
        .account .dot {
          width: 6px;
          height: 6px;
          border-radius: 50%;
          background: var(--success);
          flex-shrink: 0;
        }
        .account.active .dot {
          background: var(--success);
          box-shadow: 0 0 0 2px rgba(56,216,152,0.25);
        }
        .account .label {
          font-size: 12px;
          font-weight: 500;
          color: var(--text-1);
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .account .badge {
          display: inline-flex;
          align-items: center;
          padding: 2px 7px;
          border-radius: 999px;
          font-size: 10px;
          font-weight: 600;
          letter-spacing: 0.2px;
          text-transform: uppercase;
          background: rgba(255,255,255,0.06);
          color: var(--text-2);
          white-space: nowrap;
          flex-shrink: 0;
        }
        .account .badge.tone-success { background: color-mix(in oklab, var(--success) 18%, transparent); color: var(--success); }
        .account .badge.tone-whimsy  { background: color-mix(in oklab, var(--whimsy) 18%, transparent);  color: var(--whimsy); }
        .account .badge.tone-ember   { background: color-mix(in oklab, var(--ember) 18%, transparent);   color: var(--ember); }
        .account .badge.tone-warning { background: color-mix(in oklab, var(--warning) 18%, transparent); color: var(--warning); }
        .account .badge.tone-mercury { background: rgba(232,219,210,0.08); color: var(--mercury); }

        /* Card footer — runs + cost */
        .footer {
          display: flex;
          justify-content: space-between;
          align-items: center;
          gap: 8px;
          min-width: 0;
          padding-top: 6px;
          border-top: 1px solid rgba(255,255,255,0.06);
        }
        .footer .runs, .footer .cost {
          font-size: 11px;
          color: var(--text-2);
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .footer .cost {
          font-variant-numeric: tabular-nums;
          flex-shrink: 0;
          max-width: 60%;
        }

        /* Burn-rate rows for non-quota providers */
        .burn-list {
          display: grid;
          gap: 6px;
          align-content: start;
          padding-top: 2px;
        }
        .burn-row {
          display: flex;
          justify-content: space-between;
          align-items: baseline;
          gap: 8px;
          padding: 5px 0;
          border-bottom: 1px solid rgba(255,255,255,0.05);
        }
        .burn-row:last-child { border-bottom: none; }
        .burn-row .window {
          font-size: 12px;
          font-weight: 600;
          color: var(--text-2);
          white-space: nowrap;
        }
        .burn-row .value {
          font-size: 13px;
          font-weight: 700;
          color: var(--text-1);
          font-variant-numeric: tabular-nums;
          white-space: nowrap;
        }
        .burn-row .sub {
          font-size: 11px;
          color: var(--text-3);
          font-variant-numeric: tabular-nums;
          white-space: nowrap;
        }
        .burn-row .right {
          display: flex;
          align-items: baseline;
          gap: 8px;
          min-width: 0;
        }
        .no-quota-label {
          font-size: 11px;
          font-weight: 600;
          color: var(--text-3);
          text-transform: uppercase;
          letter-spacing: 0.6px;
          padding: 4px 0;
        }

        /* Horizontal scroll fade edges */
        .providers-wrap {
          position: relative;
        }
        .providers-wrap::before,
        .providers-wrap::after {
          content: '';
          position: absolute;
          top: 0;
          bottom: 0;
          width: 28px;
          pointer-events: none;
          z-index: 2;
          opacity: 0;
          transition: opacity 0.3s ease;
        }
        .providers-wrap.can-scroll-left::before {
          left: 0;
          opacity: 1;
          background: linear-gradient(90deg, var(--bg-top), transparent);
        }
        .providers-wrap.can-scroll-right::after {
          right: 0;
          opacity: 1;
          background: linear-gradient(-90deg, var(--bg-top), transparent);
        }
        .providers {
          scroll-behavior: smooth;
        }

        /* Currency / Token toggle */
        .value-toggle {
          display: inline-flex;
          align-items: center;
          gap: 2px;
          background: rgba(255,255,255,0.06);
          border-radius: 8px;
          padding: 3px;
        }
        .value-toggle button {
          appearance: none;
          border: none;
          background: transparent;
          color: var(--text-3);
          font-size: 12px;
          font-weight: 700;
          padding: 4px 10px;
          border-radius: 6px;
          cursor: pointer;
          font-family: inherit;
        }
        .value-toggle button.active {
          background: rgba(255,255,255,0.10);
          color: var(--text-1);
        }

        /* Provider detail overlay */
        .detail-overlay {
          position: fixed;
          inset: 0;
          z-index: 100;
          background: rgba(0,0,0,0.65);
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
          display: none;
          align-items: center;
          justify-content: center;
          padding: 24px;
        }
        .detail-overlay.active {
          display: flex;
        }
        .detail-card {
          width: 100%;
          max-width: 720px;
          max-height: 90vh;
          overflow-y: auto;
          background: var(--bg-2);
          border: 1.5px solid var(--border-strong);
          border-radius: 24px;
          padding: 24px;
          display: grid;
          gap: 16px;
          position: relative;
          box-shadow: 0 24px 48px rgba(0,0,0,0.45);
        }
        .detail-close {
          position: absolute;
          top: 16px;
          right: 16px;
          width: 36px;
          height: 36px;
          border-radius: 50%;
          background: rgba(255,255,255,0.08);
          border: none;
          color: var(--text-2);
          font-size: 18px;
          cursor: pointer;
          display: flex;
          align-items: center;
          justify-content: center;
          font-family: inherit;
        }
        .detail-header {
          display: flex;
          align-items: center;
          gap: 12px;
          padding-right: 48px;
        }
        .detail-header .logo {
          width: 40px;
          height: 40px;
          flex-shrink: 0;
          border-radius: 10px;
          overflow: hidden;
          display: flex;
          align-items: center;
          justify-content: center;
        }
        .detail-header .logo svg, .detail-header .logo img {
          width: 100%;
          height: 100%;
          display: block;
          object-fit: contain;
        }
        .detail-header .name {
          font-size: 24px;
          font-weight: 700;
          color: var(--text-1);
          letter-spacing: -0.4px;
        }
        .detail-header .pill {
          display: inline-flex;
          align-items: center;
          background: rgba(255,255,255,0.06);
          color: var(--text-2);
          font-size: 11px;
          font-weight: 600;
          padding: 3px 10px;
          border-radius: 999px;
          letter-spacing: 0.2px;
          text-transform: lowercase;
        }
        .detail-section {
          display: grid;
          gap: 8px;
        }
        .detail-section h3 {
          font-size: 11px;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.6px;
          color: var(--text-3);
          margin: 0;
        }
        .detail-row {
          display: flex;
          justify-content: space-between;
          align-items: center;
          padding: 7px 0;
          border-bottom: 1px solid rgba(255,255,255,0.05);
          gap: 12px;
        }
        .detail-row:last-child { border-bottom: none; }
        .detail-row .label {
          font-size: 14px;
          color: var(--text-2);
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .detail-row .value {
          font-size: 14px;
          font-weight: 600;
          color: var(--text-1);
          font-variant-numeric: tabular-nums;
          white-space: nowrap;
          flex-shrink: 0;
        }
        .detail-bar {
          position: relative;
          height: 6px;
          border-radius: 999px;
          background: rgba(255,255,255,0.07);
          overflow: hidden;
          margin-top: 4px;
        }
        .detail-bar .fill {
          position: absolute;
          inset: 0;
          width: 0%;
          border-radius: 999px;
          background: var(--card-accent);
          transition: width 0.6s ease;
        }
        .detail-account {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 8px;
          padding: 6px 0;
          border-bottom: 1px solid rgba(255,255,255,0.05);
        }
        .detail-account:last-child { border-bottom: none; }
        .detail-account .ident {
          display: flex;
          align-items: center;
          gap: 8px;
          min-width: 0;
        }
        .detail-account .dot {
          width: 7px;
          height: 7px;
          border-radius: 50%;
          background: var(--success);
          flex-shrink: 0;
        }
        .detail-account .label {
          font-size: 14px;
          color: var(--text-1);
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .detail-account .badge {
          font-size: 10px;
          font-weight: 600;
          padding: 2px 8px;
          border-radius: 999px;
          background: rgba(255,255,255,0.06);
          color: var(--text-2);
          text-transform: uppercase;
          letter-spacing: 0.4px;
          white-space: nowrap;
          flex-shrink: 0;
        }

        body.palette-rainbow .fill {
          background: var(--rainbow-gradient) !important;
        }
        body.palette-rainbow .segmented button.active {
          background: var(--rainbow-gradient);
          color: #1A1208;
        }
        body.palette-rainbow.bg-photoBlend::before {
          background: linear-gradient(135deg,
            color-mix(in oklab, #E40303 45%, transparent) 0%,
            color-mix(in oklab, #FF8C00 38%, transparent) 22%,
            color-mix(in oklab, #FFED00 28%, transparent) 44%,
            color-mix(in oklab, #008026 35%, transparent) 60%,
            color-mix(in oklab, #004CFF 35%, transparent) 78%,
            color-mix(in oklab, #732982 40%, transparent) 100%);
        }
        body.palette-rainbow h1 {
          background: var(--rainbow-gradient);
          -webkit-background-clip: text;
          background-clip: text;
          color: transparent;
        }

        .stage.refreshing .providers::before {
          content: '';
          position: absolute; inset: -8px;
          border-radius: 20px;
          background: linear-gradient(110deg,
            rgba(255,255,255,0) 30%,
            rgba(232,219,210,0.06) 50%,
            rgba(255,255,255,0) 70%);
          background-size: 200% 100%;
          animation: shimmer 1.6s linear infinite;
          pointer-events: none;
          z-index: 1;
        }
        @keyframes shimmer {
          0%   { background-position: 200% 0; }
          100% { background-position: -200% 0; }
        }

        /* Bridge-offline diagnostic banner */
        .stage.bridge-offline::after {
          content: 'Reconnecting to Mac…';
          position: absolute;
          top: 6px; left: 50%;
          transform: translateX(-50%);
          background: rgba(240, 192, 64, 0.16);
          color: var(--warning);
          border: 1px solid rgba(240, 192, 64, 0.35);
          padding: 4px 12px;
          border-radius: 999px;
          font-size: 11px;
          font-weight: 600;
          letter-spacing: 0.3px;
          pointer-events: none;
        }

        body.layout-bigTotal .providers { display: none; }
        body.layout-bigTotal .ambient-total { display: flex; }
        body.layout-singleProvider .card:nth-of-type(n+2) { display: none; }

        .ambient-total {
          display: none;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          gap: 8px;
          font-size: 96px;
          font-weight: 800;
          letter-spacing: -2px;
          color: var(--text-1);
        }
        .ambient-total .label {
          font-size: 16px;
          color: var(--text-2);
          letter-spacing: 1px;
          text-transform: uppercase;
        }

        /* 7" Hub vs 10" Hub Max breakpoints */
        @media (max-width: 880px) {
          .card { flex-basis: 218px; min-width: 218px; max-width: 218px; }
          .token-total { font-size: 46px; }
          .stage { padding: 14px 16px; }
        }
        @media (max-width: 640px) {
          .card { flex-basis: 200px; min-width: 200px; max-width: 200px; }
          .token-total { font-size: 40px; }
        }
      </style>
    </head>
    <body>
      <div class="stage" id="stage">
        <header class="topbar">
          <div class="brand-row">
            <img class="brand-logo" src="/brand-logo.svg" alt="OpenBurnBar">
            <span class="live-dot" aria-hidden="true"></span>
            <span id="headerStatus">live provider pressure</span>
          </div>
          <div class="controls">
            <div class="segmented" id="periods" role="tablist" aria-label="Time period"></div>
            <div class="value-toggle" id="valueToggle" role="group" aria-label="Value display mode">
              <button type="button" data-mode="currency" aria-pressed="true">$</button>
              <button type="button" data-mode="tokens" aria-pressed="false">T</button>
            </div>
            <button class="refresh-btn" id="refreshBtn" type="button" aria-label="Refresh quota data">
              <span class="spinner" aria-hidden="true"></span>
              <span class="refresh-label">Refresh</span>
            </button>
          </div>
          <div class="day-time">
            <div id="dayLabel">—</div>
            <div class="clock" id="clock">--:--</div>
          </div>
        </header>

        <div class="ambient-total" id="ambientTotal">
          <div class="label">Total</div>
          <div id="ambientValue">$0</div>
        </div>

        <div class="providers-wrap" id="providersWrap">
          <div class="providers" id="providers">
            <div class="empty">Waiting for first refresh…</div>
          </div>
        </div>

        <div class="footer-meta" id="subline" aria-live="polite" style="text-align:center;font-size:11px;color:var(--text-3);"></div>
      </div>

      <div class="detail-overlay" id="detailOverlay" aria-modal="true" role="dialog" aria-label="Provider details">
        <div class="detail-card" id="detailCard" role="document">
          <button class="detail-close" id="detailClose" type="button" aria-label="Close details">×</button>
          <div id="detailContent"></div>
        </div>
      </div>

      <script>
        const stageEl       = document.getElementById('stage');
        const clockEl       = document.getElementById('clock');
        const dayEl         = document.getElementById('dayLabel');
        const providersEl   = document.getElementById('providers');
        const periodsEl     = document.getElementById('periods');
        const refreshBtn    = document.getElementById('refreshBtn');
        const refreshLabel  = refreshBtn.querySelector('.refresh-label');
        const subEl         = document.getElementById('subline');
        const headerStatus  = document.getElementById('headerStatus');
        const ambientValue  = document.getElementById('ambientValue');
        const providersWrap = document.getElementById('providersWrap');
        const valueToggle   = document.getElementById('valueToggle');
        const detailOverlay = document.getElementById('detailOverlay');
        const detailCard    = document.getElementById('detailCard');
        const detailClose   = document.getElementById('detailClose');
        const detailContent = document.getElementById('detailContent');

        let lastVersion = -1;
        let activePeriod = null;
        let renderedPeriodOptions = '';
        let inFlightRefresh = false;
        let pollHandle = null;
        let lastPollSeconds = 5;
        let lastDisplayFingerprint = '';
        let identifyOnRefresh = false;
        let audioContext = null;
        let displayMode = localStorage.getItem('obb_displayMode') || 'currency';

        // Reliability: count consecutive /state.json failures so we can
        // (1) surface a visible diagnostic before the user thinks the
        // Hub is frozen, and (2) hard-reload the page after enough
        // failures to recover from a stuck DashCast renderer.
        let pollFailures = 0;
        let lastSuccessfulPollAt = Date.now();
        const MAX_POLL_FAILURES_BEFORE_RELOAD = 12; // ~60s at 5s cadence
        const STALE_RELOAD_MS = 10 * 60 * 1000;     // 10 min without a good poll → reload

        function tickClock() {
          const d = new Date();
          const hh = d.getHours().toString().padStart(2, '0');
          const mm = d.getMinutes().toString().padStart(2, '0');
          clockEl.textContent = `${hh}:${mm}`;
          const days = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
          const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
          dayEl.textContent = `${days[d.getDay()]}, ${months[d.getMonth()]} ${d.getDate()}`;
          if (Date.now() - lastSuccessfulPollAt > STALE_RELOAD_MS) {
            location.reload();
          }
        }
        tickClock();
        setInterval(tickClock, 30 * 1000);

        async function poll() {
          try {
            const r = await fetch('/state.json', { cache: 'no-store' });
            if (!r.ok) throw new Error('bad status ' + r.status);
            const state = await r.json();
            render(state);
            lastVersion = state.version;
            pollFailures = 0;
            lastSuccessfulPollAt = Date.now();
            stageEl.classList.remove('bridge-offline');
          } catch (e) {
            pollFailures += 1;
            stageEl.classList.add('bridge-offline');
            subEl.textContent = `Bridge offline — retrying (${pollFailures})`;
            if (pollFailures >= MAX_POLL_FAILURES_BEFORE_RELOAD) {
              location.reload();
            }
          }
        }

        function render(state) {
          applyDisplayConfig(state.display);
          renderValueToggle();

          // Header text uses server-provided strings when present, otherwise
          // fall back to a local-time clock.
          if (state.headerTimestamp) {
            const parts = state.headerTimestamp.split('  ');
            if (parts.length === 2) {
              dayEl.textContent = parts[0];
              clockEl.textContent = parts[1];
            }
          }
          if (state.headerStatus) headerStatus.textContent = state.headerStatus;
          ambientValue.textContent = state.totalSpend || '$0';

          renderPeriodPicker(state);
          renderRefreshState(state);

          subEl.textContent = state.subheadline || '';

          if (lastVersion >= 0 && state.version !== lastVersion) {
            if (state.display && state.display.audibleCue) playChime();
            if (identifyOnRefresh) {
              fetch('/voice-refresh', { method: 'POST' }).catch(() => {});
            }
          }

          if (!state.providers || state.providers.length === 0) {
            providersEl.innerHTML = '<div class="empty">No provider quota data yet</div>';
            updateScrollIndicators();
            return;
          }

          providersEl.innerHTML = '';
          for (const p of state.providers) {
            providersEl.appendChild(renderCard(p));
          }
          updateScrollIndicators();
        }

        function renderCard(p) {
          const card = document.createElement('article');
          card.className = 'card live';
          card.id = 'card-' + (p.slug || slugify(p.name));
          if (p.accentHex) {
            card.style.setProperty('--card-accent', '#' + p.accentHex);
          }

          // Top row: logo + name+freshness, status dot
          const top = document.createElement('div');
          top.className = 'top';
          const logo = document.createElement('div');
          logo.className = 'logo';
          logo.innerHTML = p.logoSVG || '';
          const topText = document.createElement('div');
          topText.className = 'top-text';
          const name = document.createElement('div');
          name.className = 'name';
          name.textContent = p.name;
          const freshness = document.createElement('div');
          freshness.className = 'freshness';
          const fresh = (p.freshnessLabel || '').trim();
          const fetchedAt = (p.fetchedAtLabel || '').trim();
          freshness.textContent = [fresh, fetchedAt].filter(Boolean).join(' · ');
          topText.appendChild(name);
          topText.appendChild(freshness);
          const dot = document.createElement('div');
          dot.className = 'top-dot';
          top.appendChild(logo);
          top.appendChild(topText);
          top.appendChild(dot);
          card.appendChild(top);

          // Status pill (omit when blank)
          if (p.statusPill) {
            const pill = document.createElement('div');
            pill.className = 'status-pill tone-' + (p.statusTone || 'mercury');
            pill.textContent = p.statusPill;
            card.appendChild(pill);
          }

          // Big token total + label
          if (p.tokenTotal) {
            const total = document.createElement('div');
            total.className = 'token-total';
            total.textContent = p.tokenTotal;
            card.appendChild(total);

            const tlabel = document.createElement('div');
            tlabel.className = 'token-label';
            tlabel.textContent = p.tokenTotalLabel || 'TOKENS';
            card.appendChild(tlabel);
          } else {
            // Without a token total the card still needs vertical rhythm.
            const spacer = document.createElement('div');
            spacer.style.height = '6px';
            card.appendChild(spacer);
          }

          // Bucket rows
          const buckets = document.createElement('div');
          buckets.className = 'bucket-list';
          (p.buckets || []).forEach(b => buckets.appendChild(renderBucket(b)));
          card.appendChild(buckets);

          // Accounts block (only when populated)
          if (p.accounts && p.accounts.length > 0) {
            card.appendChild(renderAccounts(p.accounts));
          }

          // Footer (runs + cost). Hide entirely if both empty.
          if (p.runsLabel || p.costLabel) {
            const footer = document.createElement('div');
            footer.className = 'footer';
            const runs = document.createElement('span');
            runs.className = 'runs';
            runs.textContent = p.runsLabel || '';
            const cost = document.createElement('span');
            cost.className = 'cost';
            cost.textContent = p.costLabel || '';
            footer.appendChild(runs);
            footer.appendChild(cost);
            card.appendChild(footer);
          }

          return card;
        }

        function renderBucket(b) {
          const wrap = document.createElement('div');
          wrap.className = 'bucket';
          const name = document.createElement('div');
          name.className = 'name';
          name.textContent = b.name || '';
          const value = document.createElement('div');
          value.className = 'value';
          value.textContent = b.headlineValue || (b.percent != null ? (b.percent + '%') : '');
          const bar = document.createElement('div');
          bar.className = 'bar';
          const fill = document.createElement('div');
          fill.className = 'fill tone-' + (b.tone || 'ember');
          fill.style.width = Math.min(Math.max(b.percent || 0, 0), 100) + '%';
          bar.appendChild(fill);
          const sub = document.createElement('div');
          sub.className = 'sub';
          sub.textContent = b.subLabel || '';
          wrap.appendChild(name);
          wrap.appendChild(value);
          wrap.appendChild(bar);
          if (b.subLabel) wrap.appendChild(sub);
          if (b.resetsLabel) {
            const reset = document.createElement('div');
            reset.className = 'reset';
            reset.textContent = b.resetsLabel;
            wrap.appendChild(reset);
          }
          return wrap;
        }

        function renderAccounts(accounts) {
          const wrap = document.createElement('div');
          wrap.className = 'accounts-block';
          const header = document.createElement('div');
          header.className = 'header';
          const lbl = document.createElement('span');
          lbl.textContent = 'Accounts';
          const count = document.createElement('span');
          count.className = 'count';
          count.textContent = String(accounts.length);
          header.appendChild(lbl);
          header.appendChild(count);
          wrap.appendChild(header);
          accounts.forEach(a => {
            const row = document.createElement('div');
            row.className = 'account' + (a.isActive ? ' active' : '');
            const ident = document.createElement('div');
            ident.className = 'ident';
            const dot = document.createElement('span');
            dot.className = 'dot';
            const lbl = document.createElement('span');
            lbl.className = 'label';
            lbl.textContent = a.label || '';
            ident.appendChild(dot);
            ident.appendChild(lbl);
            const badge = document.createElement('span');
            badge.className = 'badge tone-' + (a.tone || 'mercury');
            badge.textContent = a.badge || '';
            row.appendChild(ident);
            row.appendChild(badge);
            wrap.appendChild(row);
          });
          return wrap;
        }

        function slugify(s) {
          return String(s || '').toLowerCase().replace(/[^a-z0-9]/g, '');
        }

        function applyDisplayConfig(display) {
          if (!display) return;
          const fp = JSON.stringify(display);
          if (fp === lastDisplayFingerprint) return;
          lastDisplayFingerprint = fp;

          const root = document.documentElement;
          const body = document.body;
          if (display.paletteHex) {
            root.style.setProperty('--primary', display.paletteHex.primary || 'var(--ember)');
            root.style.setProperty('--secondary', display.paletteHex.secondary || 'var(--whimsy)');
          }
          body.classList.toggle('palette-rainbow', !!(display.paletteHex && display.paletteHex.rainbow));
          if (display.themeHex) {
            root.style.setProperty('--bg-top', display.themeHex.top || '#1B1610');
            root.style.setProperty('--bg-bottom', display.themeHex.bottom || '#07060A');
            root.style.setProperty('--text-1', display.themeHex.text || '#F0EBE2');
          }
          if (typeof display.brightness === 'number') {
            root.style.setProperty('--dashboard-brightness', String(display.brightness));
          }
          body.classList.remove(
            'layout-quotaCarousel', 'layout-bigTotal',
            'layout-providerGrid', 'layout-singleProvider'
          );
          if (display.layout) body.classList.add('layout-' + display.layout);
          body.classList.remove('bg-dashboard', 'bg-ambient', 'bg-photoBlend');
          body.classList.add('bg-' + (display.background || 'dashboard'));
          if (typeof display.refreshCadenceSeconds === 'number') {
            const seconds = Math.max(3, Math.min(60, display.refreshCadenceSeconds));
            if (seconds !== lastPollSeconds) {
              lastPollSeconds = seconds;
              schedulePolling();
            }
          }
          identifyOnRefresh = !!display.identifyOnRefresh;
        }

        function schedulePolling() {
          if (pollHandle) { clearInterval(pollHandle); pollHandle = null; }
          pollHandle = setInterval(poll, lastPollSeconds * 1000);
        }

        function playChime() {
          try {
            if (!audioContext) audioContext = new (window.AudioContext || window.webkitAudioContext)();
            const ctx = audioContext;
            const osc = ctx.createOscillator();
            const gain = ctx.createGain();
            osc.type = 'sine';
            osc.frequency.value = 660;
            osc.connect(gain); gain.connect(ctx.destination);
            const t = ctx.currentTime;
            gain.gain.setValueAtTime(0, t);
            gain.gain.linearRampToValueAtTime(0.06, t + 0.05);
            gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.4);
            osc.start(t); osc.stop(t + 0.45);
          } catch (e) { /* no audio permission yet */ }
        }

        function renderPeriodPicker(state) {
          const options = state.timePeriodOptions || [];
          const fingerprint = JSON.stringify(options);
          if (fingerprint !== renderedPeriodOptions) {
            periodsEl.innerHTML = '';
            for (const opt of options) {
              const btn = document.createElement('button');
              btn.type = 'button';
              btn.dataset.value = opt.value;
              btn.textContent = opt.short || opt.name || opt.value;
              btn.title = opt.name || opt.value;
              btn.setAttribute('role', 'tab');
              btn.addEventListener('click', () => selectPeriod(opt.value));
              periodsEl.appendChild(btn);
            }
            renderedPeriodOptions = fingerprint;
          }
          activePeriod = state.timePeriod;
          for (const btn of periodsEl.querySelectorAll('button')) {
            btn.classList.toggle('active', btn.dataset.value === state.timePeriod);
            btn.setAttribute('aria-selected', btn.dataset.value === state.timePeriod ? 'true' : 'false');
          }
        }

        function renderRefreshState(state) {
          const refreshing = !!state.isRefreshing || inFlightRefresh;
          stageEl.classList.toggle('refreshing', refreshing);
          refreshBtn.classList.toggle('refreshing', refreshing);
          refreshBtn.disabled = refreshing;
          refreshLabel.textContent = refreshing ? 'Refreshing…' : 'Refresh';
        }

        async function selectPeriod(value) {
          if (value === activePeriod) return;
          activePeriod = value;
          for (const btn of periodsEl.querySelectorAll('button')) {
            btn.classList.toggle('active', btn.dataset.value === value);
            btn.setAttribute('aria-selected', btn.dataset.value === value ? 'true' : 'false');
          }
          try {
            await fetch('/period?p=' + encodeURIComponent(value), { method: 'POST' });
          } catch (e) { /* poll() will reconcile */ }
          poll();
        }

        async function triggerRefresh() {
          if (inFlightRefresh) return;
          inFlightRefresh = true;
          renderRefreshState({ isRefreshing: true });
          try {
            const r = await fetch('/refresh', { method: 'POST' });
            if (!r.ok) throw new Error('bad status ' + r.status);
          } catch (e) {
            subEl.textContent = 'Refresh failed — retry?';
          } finally {
            inFlightRefresh = false;
            poll();
          }
        }

        refreshBtn.addEventListener('click', triggerRefresh);

        poll();
        schedulePolling();
      </script>
    </body>
    </html>
    """##

    static let brandLogoSVG: String = ##"""
    <svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" fill="none" viewBox="0 0 256 256">
      <path d="m219.4 165.8c0-21.55-6.09-42.7-16.19-59.49-2.04-3.41-6.29-1.8-6.69 2.14-1.54 11.73-4.28 20.86-14.29 30.79-1.3 1.29-2.17 2.08-0.96 4.08 1.07 1.85 4.11 1.49 6.21 1.41 3.37-0.13 4.7 1.8 4.7 4.8v76.33c15.87-15.69 27.22-35.75 27.22-60.06z" fill="url(#paint0_linear_6134_26115)"/>
      <path d="m183.6 150.6h-21.89c-2.15 0-3.89 0.97-3.89 3.57v92.2c10.94-4.19 20.1-9.63 27.85-15.75v-76.3c0-2.04-0.85-3.72-2.07-3.72z" fill="url(#paint1_linear_6134_26115)"/>
      <path d="m148.8 176.9h-21.01c-2.06 0-2.9 1.26-2.9 2.98v72.1c10.37-0.36 19.37-2.07 26.57-3.99v-68.16c0-1.67-1.27-2.93-2.66-2.93z" fill="url(#paint2_linear_6134_26115)"/>
      <path d="m116.2 195.9c-0.69-0.73-1.51-0.66-1.84-0.66h-20.24c-2.11 0-2.79 1.59-2.79 3.03v49.68c9.02 2.79 17.47 4.02 27.17 4.02v-53.62c0-0.63-0.55-2.02-2.3-2.45z" fill="url(#paint3_linear_6134_26115)"/>
      <path d="m82.41 216.6h-20.89c-1.61 0-2.91 1.17-2.91 2.89v10.4c8.19 7.67 17.28 13.09 26.13 16.29v-26.69c0-1.64-0.9-2.89-2.33-2.89z" fill="url(#paint4_linear_6134_26115)"/>
      <path d="m171.6 4.7c-1.76-1.09-3.67-0.59-4.86 0.45-22.97 19.26-45.45 45.79-53.94 93.11-2.72-10.13-5.91-14.48-12.12-21.43-3.3-2.68-6.7-0.6-5.98 2.8 7.11 15.71 2.97 29.15-14.11 45.44-0.98-5.2-0.96-10.96-0.31-17.18 0.47-2.92-3.2-4.55-5.22-2.08-19 21.58-39.35 47.26-39.35 77.2 0 14.8 6.29 29.97 16.59 41.19v-10.57c0-3.25 1.91-4.06 4.55-4.02h25.35c-11.5-17.34-4.46-38.39 21.13-64.72-1.17 5.44-2.31 19 9.2 23.86 15.15 5.05 43.43-12.47 54.79-35.59 9.39-22.1-3.56-39.03-8.41-61.05-5.01-22.73 0.3-43.3 12.97-64.04 1.54-2.2 0.43-2.93-0.28-3.37z" fill="url(#paint5_linear_6134_26115)"/>
      <path d="m166.3 5.83c-14.59 12.24-34.96 35.89-42.37 73.87-3.09 15.13-3.55 37.15-24.66 55.28-11.88 9.28-19.63 9.14-23.24 8.03-9.82-3.1-10.35-15.14-2.36-30.09-13.74 15.26-30.5 37.84-25.93 69.99 0.79 5.76 1.74 9.02 1.74 9.02 4.76-20.73 23.46-30.79 37.96-42.32 20.2-14.5 33.51-32.46 36.2-61.5 3.3-29.03 13.97-51.05 42.66-82.28z" fill="url(#paint6_linear_6134_26115)"/>
      <path d="m73.64 112.9c-13.46 14.27-14.76 33.74-2.65 38.15-10.81 2.96-17.48 15.31-21.82 26.75-4.25-10.94-3.14-30.51 24.47-64.9z" fill="url(#paint7_linear_6134_26115)"/>
      <path d="m167.2 4.7c-16.79 12.71-31.4 40.29-28.27 73.41 1.19 13.03 5.97 27.04 3.11 41.98-4.56 22.19-21.12 35.72-31.54 39.31-4.07-3.64-6.72-7.92-6.72-14.96-1.08 3.24-3.28 14.68 5.28 22.44 12 7.77 38.91-5.09 54.81-28.78 11.93-19.92 5.03-35.31-0.86-53.39-9.91-27.78-5.91-49.51 8.39-75.96 1.78-2.82 0.8-5.11-4.2-4.05z" fill="url(#paint8_linear_6134_26115)"/>
      <defs>
        <linearGradient id="paint0_linear_6134_26115" x1="182.1" x2="227.7" y1="110.1" y2="199.8" gradientUnits="userSpaceOnUse"><stop stop-color="#E31B24" offset="0"/><stop stop-color="#B01127" offset="1"/></linearGradient>
        <linearGradient id="paint1_linear_6134_26115" x1="158.4" x2="201.6" y1="155.9" y2="231.4" gradientUnits="userSpaceOnUse"><stop stop-color="#E31B24" offset="0"/><stop stop-color="#B01127" offset="1"/></linearGradient>
        <linearGradient id="paint2_linear_6134_26115" x1="123.1" x2="161.2" y1="179.2" y2="248" gradientUnits="userSpaceOnUse"><stop stop-color="#E74C16" offset="0"/><stop stop-color="#E04016" offset="1"/></linearGradient>
        <linearGradient id="paint3_linear_6134_26115" x1="89.8" x2="123.1" y1="198.1" y2="249.8" gradientUnits="userSpaceOnUse"><stop stop-color="#F4831F" offset="0"/><stop stop-color="#F0671A" offset="1"/></linearGradient>
        <linearGradient id="paint4_linear_6134_26115" x1="56.65" x2="81.01" y1="217.8" y2="250.4" gradientUnits="userSpaceOnUse"><stop stop-color="#FCC827" offset="0"/><stop stop-color="#FEA41C" offset="1"/></linearGradient>
        <linearGradient id="paint5_linear_6134_26115" x1="105.8" x2="105.8" y1="4" y2="224.2" gradientUnits="userSpaceOnUse"><stop stop-color="#FDBA12" offset="0"/><stop stop-color="#F66005" offset=".4844"/><stop stop-color="#F25205" offset="1"/></linearGradient>
        <linearGradient id="paint6_linear_6134_26115" x1="105.8" x2="105.8" y1="5.828" y2="191.9" gradientUnits="userSpaceOnUse"><stop stop-color="#FED430" offset="0"/><stop stop-color="#FEA41C" offset=".5052"/><stop stop-color="#FE9111" offset="1"/></linearGradient>
        <linearGradient id="paint7_linear_6134_26115" x1="61.22" x2="61.22" y1="112.9" y2="177.8" gradientUnits="userSpaceOnUse"><stop stop-color="#FEA21C" offset="0"/><stop stop-color="#FEA21C" stop-opacity=".25" offset="1"/></linearGradient>
        <linearGradient id="paint8_linear_6134_26115" x1="138.6" x2="138.6" y1="4.441" y2="169.7" gradientUnits="userSpaceOnUse"><stop stop-color="#FEA41C" offset="0"/><stop stop-color="#F76D05" offset=".4896"/><stop stop-color="#E60000" offset=".9635"/></linearGradient>
      </defs>
    </svg>
    """##
}
