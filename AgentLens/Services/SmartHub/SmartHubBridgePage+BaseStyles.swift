import Foundation

extension SmartHubBridgePage {

    static let htmlBaseStyles: String = ##"""
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
          touch-action: pan-y;
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
          scroll-snap-type: x proximity;
          scrollbar-width: none;
          -webkit-overflow-scrolling: touch;
          touch-action: pan-y;
          overscroll-behavior-x: contain;
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
          touch-action: pan-y;
          user-select: none;
          -webkit-user-select: none;
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
          font-size: clamp(28px, 10vw, 54px);
          font-weight: 800;
          letter-spacing: -2px;
          color: var(--text-1);
          line-height: 1.0;
          margin-top: 2px;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
          max-width: 100%;
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

    """##
}
