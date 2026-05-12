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
        .brand-row .mark {
          width: 28px; height: 28px;
          background: linear-gradient(135deg, var(--primary) 0%, color-mix(in oklab, var(--primary) 60%, black) 100%);
          mask-image: radial-gradient(circle at 30% 30%, transparent 30%, black 30%);
          -webkit-mask-image: radial-gradient(circle at 30% 30%, transparent 30%, black 30%);
          border-radius: 6px;
          position: relative;
        }
        .brand-row .mark::after {
          content: '';
          position: absolute;
          inset: 6px;
          background: var(--text-1);
          clip-path: polygon(50% 0%, 100% 100%, 0% 100%);
          opacity: 0.95;
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

        .accounts-block { margin-top: 4px; }
        .accounts-block .header {
          display: flex; justify-content: space-between; align-items: baseline;
          font-size: 11px;
          font-weight: 600;
          letter-spacing: 1.6px;
          color: var(--text-3);
          text-transform: uppercase;
          padding-bottom: 6px;
          border-bottom: 1px solid rgba(255,255,255,0.06);
        }
        .accounts-block .count { color: var(--text-2); letter-spacing: 0; }
        .account {
          display: grid;
          grid-template-columns: 1fr auto;
          align-items: center;
          gap: 8px;
          padding: 6px 0 5px;
          border-bottom: 1px solid rgba(255,255,255,0.04);
        }
        .account:last-child { border-bottom: 0; }
        .account .ident {
          display: flex; align-items: center; gap: 8px;
          min-width: 0;
        }
        .account .dot {
          width: 6px; height: 6px; border-radius: 50%;
          background: rgba(255,255,255,0.22);
          flex: 0 0 6px;
        }
        .account.active .dot { background: var(--success); }
        .account .label {
          font-size: 12px;
          font-weight: 500;
          color: var(--text-1);
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .badge {
          font-size: 9px;
          font-weight: 700;
          letter-spacing: 0.8px;
          padding: 2px 8px;
          border-radius: 999px;
          background: rgba(255,255,255,0.08);
          color: var(--text-2);
        }
        .badge.tone-success { background: color-mix(in oklab, var(--success) 25%, transparent); color: var(--success); }
        .badge.tone-whimsy  { background: color-mix(in oklab, var(--whimsy) 25%, transparent);  color: var(--whimsy); }
        .badge.tone-ember   { background: color-mix(in oklab, var(--ember) 25%, transparent);   color: var(--ember); }
        .badge.tone-mercury { background: rgba(232,219,210,0.12); color: var(--mercury); }
        .badge.tone-warning { background: color-mix(in oklab, var(--warning) 25%, transparent); color: var(--warning); }

        .footer {
          display: flex;
          justify-content: space-between;
          align-items: baseline;
          font-size: 13px;
          padding-top: 8px;
          border-top: 1px solid rgba(255,255,255,0.07);
        }
        .footer .runs  { color: var(--text-2); font-weight: 500; font-variant-numeric: tabular-nums; }
        .footer .cost  { color: var(--text-1); font-weight: 700; font-variant-numeric: tabular-nums; }
        .footer:empty { display: none; }

        /* Refresh shimmer */
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
            <div class="mark" aria-hidden="true"></div>
            <span class="live-dot" aria-hidden="true"></span>
            <span id="headerStatus">live provider pressure</span>
          </div>
          <div class="controls">
            <div class="segmented" id="periods" role="tablist" aria-label="Time period"></div>
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

        <div class="providers" id="providers">
          <div class="empty">Waiting for first refresh…</div>
        </div>

        <div class="footer-meta" id="subline" aria-live="polite" style="text-align:center;font-size:11px;color:var(--text-3);"></div>
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

        let lastVersion = -1;
        let activePeriod = null;
        let renderedPeriodOptions = '';
        let inFlightRefresh = false;
        let pollHandle = null;
        let lastPollSeconds = 5;
        let lastDisplayFingerprint = '';
        let identifyOnRefresh = false;
        let audioContext = null;

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
            return;
          }

          providersEl.innerHTML = '';
          for (const p of state.providers) {
            providersEl.appendChild(renderCard(p));
          }
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
}
