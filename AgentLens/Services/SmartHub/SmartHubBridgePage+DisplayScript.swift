import Foundation

extension SmartHubBridgePage {

    static let htmlDisplayScript: String = ##"""

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

        function triggerIdentifyVoice() {
          if (identifyVoiceInFlight) return;
          identifyVoiceInFlight = true;
          fetch(bridgePath('/voice-refresh'), { method: 'POST' })
            .catch(() => {})
            .finally(() => { identifyVoiceInFlight = false; });
        }

        function handleVoiceEvent(voice) {
          if (!voice) return;
          const eventId = Number(voice.eventId || 0);
          const message = String(voice.message || '').trim();
          if (!eventId || eventId <= lastVoiceEventId || !message) return;

          const queuedAt = Date.parse(String(voice.queuedAt || voice.requestedAt || ''));
          if (Number.isFinite(queuedAt)) {
            const predatesPage = queuedAt < pageLoadedAt - PAGE_LOAD_VOICE_GRACE_MS;
            const expired = Date.now() - queuedAt > VOICE_EVENT_MAX_AGE_MS;
            if (predatesPage || expired) {
              markVoiceEventConsumed(eventId);
              return;
            }
          }

          markVoiceEventConsumed(eventId);
          subEl.textContent = message;

          stageEl.classList.remove('voice-pulse');
          void stageEl.offsetWidth;
          stageEl.classList.add('voice-pulse');
          window.setTimeout(() => stageEl.classList.remove('voice-pulse'), 1300);

          speakVoiceMessage(message);
        }

        function markVoiceEventConsumed(eventId) {
          lastVoiceEventId = Math.max(lastVoiceEventId, eventId);
          try { sessionStorage.setItem('obb_lastVoiceEventId', String(lastVoiceEventId)); } catch (_) {}
        }

        function speakVoiceMessage(message) {
          try {
            if ('speechSynthesis' in window && 'SpeechSynthesisUtterance' in window) {
              window.speechSynthesis.cancel();
              const utterance = new SpeechSynthesisUtterance(message);
              utterance.rate = 0.95;
              utterance.pitch = 1.0;
              utterance.volume = 1.0;
              let started = false;
              let fallbackPlayed = false;
              const playFallback = () => {
                if (fallbackPlayed) return;
                fallbackPlayed = true;
                playChime();
              };
              const fallbackTimer = window.setTimeout(() => {
                if (!started) playFallback();
              }, 1200);
              utterance.onstart = () => {
                started = true;
                window.clearTimeout(fallbackTimer);
              };
              utterance.onerror = () => {
                window.clearTimeout(fallbackTimer);
                playFallback();
              };
              utterance.onend = () => {
                window.clearTimeout(fallbackTimer);
              };
              window.speechSynthesis.speak(utterance);
              return;
            }
          } catch (_) {
            // Fall through to chime fallback.
          }
          playChime();
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
            await fetch(bridgePath('/period?p=' + encodeURIComponent(value)), { method: 'POST' });
          } catch (e) { /* poll() will reconcile */ }
          poll();
        }

        async function triggerRefresh() {
          if (inFlightRefresh) return;
          inFlightRefresh = true;
          renderRefreshState({ isRefreshing: true });
          try {
            const r = await fetch(bridgePath('/refresh'), { method: 'POST' });
            if (!r.ok) throw new Error('bad status ' + r.status);
          } catch (e) {
            subEl.textContent = 'Refresh failed — retry?';
          } finally {
            inFlightRefresh = false;
            poll();
          }
        }

        refreshBtn.addEventListener('click', triggerRefresh);

        renderValueToggle();

        poll();
        schedulePolling();
    """##
}
