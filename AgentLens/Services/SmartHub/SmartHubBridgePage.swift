import Foundation

// MARK: - Smart Hub Bridge — Static Page
//
// The HTML the Nest Hub renders. Polls /state.json every 5s and reloads
// when the server-bumped `version` increments. Designed for the 10"
// Nest Hub Max display: dark background, large numerals, no scroll bars.
//
// Surfaces the user-selected time-period as a segmented control along the
// top, plus a real refresh button that POSTs /refresh and reflects the
// `isRefreshing` flag with a shimmer overlay so the device proves it
// heard the tap. Each provider row carries a small window chip ("5h",
// "7d", …) describing which underlying bucket the row reflects.

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
          --bg-top: #2a221a;
          --bg-bottom: var(--bg-1);
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
          background: radial-gradient(1200px 800px at 80% 110%, var(--bg-top) 0%, var(--bg-bottom) 60%);
          font-family: -apple-system, "SF Pro Rounded", "SF Pro", system-ui, sans-serif;
          color: var(--text-1);
          overflow: hidden;
          filter: brightness(var(--dashboard-brightness));
          transition: filter 0.35s ease, background 0.35s ease;
        }
        body.layout-bigTotal .providers { display: none; }
        body.layout-providerGrid .providers { grid-template-columns: repeat(2, 1fr); }
        body.layout-singleProvider .providers > .row:nth-of-type(n+2) { display: none; }
        body.layout-singleProvider .providers { grid-template-columns: 1fr; }
        body.bg-ambient .providers { display: none; }
        body.bg-ambient .spend { font-size: 152px; }
        body.bg-photoBlend::before {
          content: '';
          position: absolute; inset: 0;
          background: linear-gradient(135deg,
            color-mix(in oklab, var(--primary) 55%, transparent) 0%,
            color-mix(in oklab, var(--secondary) 25%, transparent) 60%,
            transparent 100%);
          pointer-events: none;
          z-index: 0;
        }
        body.bg-photoBlend .stage { z-index: 1; position: relative; }
        .stage {
          display: grid;
          grid-template-rows: auto auto 1fr auto;
          gap: 18px;
          height: 100vh;
          padding: 28px 36px 28px;
          position: relative;
        }
        header {
          display: flex; align-items: center; justify-content: space-between;
        }
        h1 {
          font-size: 26px; font-weight: 700; letter-spacing: -0.5px; margin: 0;
        }
        .clock {
          font-variant-numeric: tabular-nums;
          font-size: 18px; color: var(--text-2);
        }
        .controls {
          display: flex;
          gap: 12px;
          align-items: center;
          justify-content: space-between;
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
          font-size: 14px;
          font-weight: 600;
          padding: 8px 14px;
          min-width: 52px;
          border-radius: 999px;
          cursor: pointer;
          font-family: inherit;
          transition: background 0.18s ease, color 0.18s ease;
        }
        .segmented button.active {
          background: linear-gradient(135deg, var(--primary) 0%, color-mix(in oklab, var(--primary) 60%, black) 100%);
          color: var(--text-1);
          box-shadow: 0 1px 2px rgba(0,0,0,0.3);
        }
        .segmented button:focus-visible {
          outline: 2px solid var(--mercury);
          outline-offset: 2px;
        }
        .refresh-btn {
          appearance: none;
          background: rgba(255,255,255,0.04);
          color: var(--text-1);
          border: 1px solid var(--border);
          border-radius: 999px;
          padding: 9px 16px;
          font-size: 14px;
          font-weight: 600;
          cursor: pointer;
          font-family: inherit;
          display: inline-flex; align-items: center; gap: 8px;
          transition: background 0.18s ease, transform 0.18s ease;
        }
        .refresh-btn[disabled] {
          opacity: 0.55; cursor: progress;
        }
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
        @keyframes spin {
          to { transform: rotate(360deg); }
        }
        .total {
          align-self: center;
        }
        .spend {
          font-size: 96px; font-weight: 800; letter-spacing: -2px;
          color: var(--text-1);
          line-height: 1.0;
        }
        .headline {
          font-size: 22px; color: var(--text-2); margin-top: 12px;
        }
        .sub {
          font-size: 15px; color: var(--text-3); margin-top: 4px;
        }
        .providers {
          display: grid; grid-template-columns: repeat(2, 1fr);
          gap: 14px; align-content: end;
          position: relative;
        }
        .row {
          padding: 14px 16px;
          border: 1px solid var(--border);
          border-radius: 14px;
          background: rgba(255,255,255,0.02);
          display: grid; grid-template-rows: auto auto auto; gap: 8px;
          position: relative;
        }
        .row .top {
          display: flex; justify-content: space-between; align-items: center; gap: 8px;
        }
        .row .name {
          font-size: 16px; font-weight: 600;
        }
        .row .window {
          font-size: 11px;
          font-weight: 600;
          color: var(--text-3);
          background: rgba(255,255,255,0.05);
          border: 1px solid var(--border);
          padding: 2px 8px;
          border-radius: 999px;
          letter-spacing: 0.4px;
          text-transform: uppercase;
        }
        .row .label {
          font-size: 13px; color: var(--text-2);
          font-variant-numeric: tabular-nums;
        }
        .bar {
          position: relative;
          height: 8px;
          border-radius: 999px;
          background: rgba(255,255,255,0.07);
          overflow: hidden;
        }
        .fill {
          position: absolute; inset: 0; width: 0%;
          border-radius: 999px;
          background: var(--ember);
          transition: width 0.6s ease;
        }
        .fill.tone-ember   { background: var(--primary); }
        .fill.tone-whimsy  { background: var(--secondary); }
        .fill.tone-success { background: var(--success); }
        .fill.tone-warning { background: var(--warning); }
        .fill.tone-mercury { background: var(--mercury); }

        .stage.refreshing .providers::before {
          content: '';
          position: absolute; inset: -8px;
          border-radius: 18px;
          background: linear-gradient(110deg,
            rgba(255,255,255,0) 30%,
            rgba(232,219,210,0.10) 50%,
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

        .empty {
          align-self: center;
          text-align: center;
          color: var(--text-3);
          font-size: 18px;
        }

        /* Visible diagnostic when /state.json polling fails. Without
           this, a stuck Nest Hub looks indistinguishable from a healthy
           one with no recent activity. */
        .stage.bridge-offline #sub {
          color: var(--warning);
          font-weight: 600;
        }
        .stage.bridge-offline::after {
          content: 'Reconnecting to Mac…';
          position: absolute;
          top: 12px; left: 50%;
          transform: translateX(-50%);
          background: rgba(240, 192, 64, 0.16);
          color: var(--warning);
          border: 1px solid rgba(240, 192, 64, 0.35);
          padding: 4px 12px;
          border-radius: 999px;
          font-size: 12px;
          font-weight: 600;
          letter-spacing: 0.3px;
          pointer-events: none;
        }

        @media (max-width: 760px) {
          .stage { padding: 18px 22px; }
          .spend { font-size: 64px; }
          .providers { grid-template-columns: 1fr; }
          .controls { flex-direction: column; align-items: stretch; }
        }
      </style>
    </head>
    <body>
      <div class="stage" id="stage">
        <header>
          <h1>OpenBurnBar</h1>
          <div class="clock" id="clock">--:--</div>
        </header>

        <div class="controls">
          <div class="segmented" id="periods" role="tablist" aria-label="Time period"></div>
          <button class="refresh-btn" id="refreshBtn" type="button" aria-label="Refresh quota data">
            <span class="spinner" aria-hidden="true"></span>
            <span class="refresh-label">Refresh</span>
          </button>
        </div>

        <div class="total">
          <div class="spend" id="spend">$0</div>
          <div class="headline" id="headline">Loading…</div>
          <div class="sub" id="sub">Connecting to your Mac</div>
        </div>

        <div class="providers" id="providers">
          <div class="empty">Waiting for first refresh…</div>
        </div>
      </div>

      <script>
        const stageEl = document.getElementById('stage');
        const clockEl = document.getElementById('clock');
        const spendEl = document.getElementById('spend');
        const headlineEl = document.getElementById('headline');
        const subEl = document.getElementById('sub');
        const providersEl = document.getElementById('providers');
        const periodsEl = document.getElementById('periods');
        const refreshBtn = document.getElementById('refreshBtn');
        const refreshLabel = refreshBtn.querySelector('.refresh-label');

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
          // If the page has been alive for too long with no successful
          // poll, force a reload. DashCast tends to leak DOM nodes /
          // keep stale JS state when left running for hours.
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
              // Last-resort: full page reload. Recovers from cases where
              // the page's fetch state machine is wedged but the bridge
              // would be reachable on a fresh load.
              location.reload();
            }
          }
        }

        function render(state) {
          applyDisplayConfig(state.display);

          spendEl.textContent = state.totalSpend || '$0';
          headlineEl.textContent = state.headline || 'OpenBurnBar';
          subEl.textContent = state.subheadline || `Updated ${new Date().toLocaleTimeString()}`;

          renderPeriodPicker(state);
          renderRefreshState(state);

          // Audible cue / identify on version bump.
          if (lastVersion >= 0 && state.version !== lastVersion) {
            if (state.display && state.display.audibleCue) {
              playChime();
            }
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
            const row = document.createElement('div');
            row.className = 'row';
            const window = (p.window || '').trim();
            row.innerHTML = `
              <div class="top">
                <div class="name">${escape(p.name)}</div>
                ${window ? `<div class="window">${escape(window)}</div>` : ''}
              </div>
              <div class="bar"><div class="fill tone-${p.tone || 'ember'}" style="width:${Math.min(Math.max(p.percent || 0, 0), 100)}%"></div></div>
              <div class="label">${escape(p.label)}</div>
            `;
            providersEl.appendChild(row);
          }
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
            root.style.setProperty('--bg-top', display.themeHex.top || '#2a221a');
            root.style.setProperty('--bg-bottom', display.themeHex.bottom || '#0E0D0B');
            root.style.setProperty('--text-1', display.themeHex.text || '#F0EBE2');
          }
          if (typeof display.brightness === 'number') {
            root.style.setProperty('--dashboard-brightness', String(display.brightness));
          }
          body.classList.remove(
            'layout-quotaCarousel', 'layout-bigTotal',
            'layout-providerGrid', 'layout-singleProvider'
          );
          if (display.layout) {
            body.classList.add('layout-' + display.layout);
          }
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
          if (pollHandle) {
            clearInterval(pollHandle);
            pollHandle = null;
          }
          pollHandle = setInterval(poll, lastPollSeconds * 1000);
        }

        function playChime() {
          try {
            if (!audioContext) {
              audioContext = new (window.AudioContext || window.webkitAudioContext)();
            }
            const ctx = audioContext;
            const osc = ctx.createOscillator();
            const gain = ctx.createGain();
            osc.type = 'sine';
            osc.frequency.value = 660;
            osc.connect(gain);
            gain.connect(ctx.destination);
            const t = ctx.currentTime;
            gain.gain.setValueAtTime(0, t);
            gain.gain.linearRampToValueAtTime(0.06, t + 0.05);
            gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.4);
            osc.start(t);
            osc.stop(t + 0.45);
          } catch (e) {
            // No audio permission yet (Nest Hub gates user gestures).
          }
        }

        function renderPeriodPicker(state) {
          const options = state.timePeriodOptions || [];
          const fingerprint = JSON.stringify(options);
          const periodChanged = state.timePeriod !== activePeriod;
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
          if (periodChanged || fingerprint !== renderedPeriodOptions) {
            activePeriod = state.timePeriod;
            for (const btn of periodsEl.querySelectorAll('button')) {
              btn.classList.toggle('active', btn.dataset.value === state.timePeriod);
              btn.setAttribute('aria-selected', btn.dataset.value === state.timePeriod ? 'true' : 'false');
            }
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
          } catch (e) {
            // Best-effort — next poll() will reconcile.
          }
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
            // Surface the failure subtly; next poll() will reset.
            subEl.textContent = 'Refresh failed — retry?';
          } finally {
            inFlightRefresh = false;
            poll();
          }
        }

        refreshBtn.addEventListener('click', triggerRefresh);

        function escape(s) {
          return String(s ?? '').replace(/[&<>"]/g, c => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
          }[c]));
        }

        poll();
        schedulePolling();
      </script>
    </body>
    </html>
    """##
}
