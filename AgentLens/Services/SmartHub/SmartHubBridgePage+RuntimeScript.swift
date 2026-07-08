import Foundation

extension SmartHubBridgePage {

    static let htmlRuntimeScript: String = ##"""
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
        const scrollLeftBtn = document.getElementById('scrollLeft');
        const scrollRightBtn = document.getElementById('scrollRight');
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
        const pageLoadedAt = Date.now();
        const PAGE_LOAD_VOICE_GRACE_MS = 1500;
        const VOICE_EVENT_MAX_AGE_MS = 2 * 60 * 1000;
        let lastVoiceEventId = Number(sessionStorage.getItem('obb_lastVoiceEventId') || '0');
        let lastRefreshingState = false;
        let identifyVoiceInFlight = false;
        const bridgeToken = new URLSearchParams(window.location.search).get('bridgeToken') || '';

        function bridgePath(path) {
          const url = new URL(path, window.location.origin);
          if (bridgeToken) url.searchParams.set('bridgeToken', bridgeToken);
          return url.pathname + url.search;
        }

        // Reliability: count consecutive /state.json failures so we can
        // (1) surface a visible diagnostic before the user thinks the
        // Hub is frozen, and (2) hard-reload the page after enough
        // failures to recover from a stuck DashCast renderer.
        let pollFailures = 0;
        let lastSuccessfulPollAt = Date.now();
        const MAX_POLL_FAILURES_BEFORE_RELOAD = 12; // ~60s at 5s cadence
        // Eat a single transient blip — a packet loss or a 1s bridge restart
        // shouldn't flash the alarmist "Reconnecting to Mac…" pill. Only
        // surface the offline UI once two consecutive polls have failed
        // (~10s), which still beats the Mac-side watchdog (30s) to the punch.
        const FAILURES_BEFORE_OFFLINE_UI = 2;
        const STALE_RELOAD_MS = 10 * 60 * 1000;     // 10 min without a good poll → reload

        // Persist the last good /state.json to sessionStorage so a hard
        // reload (after MAX_POLL_FAILURES_BEFORE_RELOAD or
        // STALE_RELOAD_MS) rehydrates the dashboard immediately rather
        // than flashing "Waiting for first refresh…" while the new poll
        // round-trips. The cache is per-session, so it never outlives
        // the WebView; if DashCast tears down, we start fresh.
        const STATE_CACHE_KEY = 'obb_cachedState';
        try {
          const cached = sessionStorage.getItem(STATE_CACHE_KEY);
          if (cached) {
            const cachedState = JSON.parse(cached);
            if (cachedState && typeof cachedState === 'object') {
              try {
                render(cachedState);
                // Treat rehydrated data as offline until the first live
                // poll succeeds — the orange "Reconnecting to Mac…" pill
                // tells the user what they're looking at is stale.
                stageEl.classList.add('bridge-offline');
              } catch (_) {
                // Schema mismatch between cache and current render() —
                // wipe so we never re-hit it.
                sessionStorage.removeItem(STATE_CACHE_KEY);
              }
            }
          }
        } catch (_) {
          // Corrupt or unavailable storage — drop it; next render reseeds.
        }

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
            const r = await fetch(bridgePath('/state.json'), { cache: 'no-store' });
            if (!r.ok) throw new Error('bad status ' + r.status);
            const state = await r.json();
            render(state);
            lastVersion = state.version;
            pollFailures = 0;
            lastSuccessfulPollAt = Date.now();
            stageEl.classList.remove('bridge-offline');
            // Cache the latest good payload so a hard reload (or a
            // future tab re-attach) starts with real data instead of
            // the "Waiting for first refresh…" placeholder.
            try { sessionStorage.setItem(STATE_CACHE_KEY, JSON.stringify(state)); } catch (_) {}
          } catch (e) {
            pollFailures += 1;
            if (pollFailures >= FAILURES_BEFORE_OFFLINE_UI) {
              stageEl.classList.add('bridge-offline');
              subEl.textContent = `Bridge offline — retrying (${pollFailures})`;
            }
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
          ambientValue.textContent = displayMode === 'currency'
            ? (state.totalSpend || '$0')
            : (state.totalTokens || '—');

          renderPeriodPicker(state);
          renderRefreshState(state);

          subEl.textContent = state.subheadline || '';
          handleVoiceEvent(state.voice);

          const isVersionChange = lastVersion >= 0 && state.version !== lastVersion;
          const isRefreshing = !!state.isRefreshing;
          if (isVersionChange) {
            if (state.display && state.display.audibleCue) playChime();
            if (identifyOnRefresh && lastRefreshingState && !isRefreshing) {
              triggerIdentifyVoice();
            }
          }
          lastRefreshingState = isRefreshing;

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
    """##
}
