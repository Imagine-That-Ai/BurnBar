import Foundation

extension SmartHubBridgePage {

    static let htmlInteractionScript: String = ##"""

        function updateScrollIndicators() {
          if (!providersWrap || !providersEl) return;
          const canLeft = providersEl.scrollLeft > 4;
          const canRight = providersEl.scrollLeft + providersEl.clientWidth < providersEl.scrollWidth - 4;
          providersWrap.classList.toggle('can-scroll-left', canLeft);
          providersWrap.classList.toggle('can-scroll-right', canRight);
          if (scrollLeftBtn) scrollLeftBtn.classList.toggle('visible', canLeft);
          if (scrollRightBtn) scrollRightBtn.classList.toggle('visible', canRight);
        }
        let providerScreenSwipe = null;
        let suppressNextCardClick = false;
        let lastProviderPointerTouchAt = { value: 0 };

        function providerRailCanScroll() {
          return providersEl && providersEl.scrollWidth > providersEl.clientWidth + 4;
        }

        function shouldIgnoreProviderSwipeStart(target) {
          if (!target || !target.closest) return false;
          if (detailOverlay && detailOverlay.classList.contains('active')) return true;
          if (target.closest('.detail-overlay, .detail-card')) return true;
          if (target.closest('.card')) return false;
          return Boolean(target.closest('button, input, select, textarea, a, .segmented, .value-toggle, .refresh-btn, .scroll-btn'));
        }

        function beginProviderSwipeAt(x, y, target, pointerId, source) {
          if (!stageEl || !providerRailCanScroll()) return;
          if (shouldIgnoreProviderSwipeStart(target)) return;
          if (providerScreenSwipe && providerScreenSwipe.active) return;
          providerScreenSwipe = {
            pointerId,
            source,
            startX: x,
            startY: y,
            lastX: x,
            active: false
          };
        }

        function moveProviderSwipeTo(x, y, event, pointerId, source) {
          if (!providerScreenSwipe || providerScreenSwipe.pointerId !== pointerId || providerScreenSwipe.source !== source) return;
          const dx = x - providerScreenSwipe.startX;
          const dy = y - providerScreenSwipe.startY;
          if (!providerScreenSwipe.active) {
            if (Math.abs(dx) < 10 || Math.abs(dx) < Math.abs(dy) * 1.2) return;
            providerScreenSwipe.active = true;
            suppressNextCardClick = true;
          }
          if (event && event.cancelable) event.preventDefault();
          const step = providerScreenSwipe.lastX - x;
          providersEl.scrollLeft += step;
          providerScreenSwipe.lastX = x;
          updateScrollIndicators();
        }

        function endProviderSwipe(pointerId, source) {
          if (!providerScreenSwipe || providerScreenSwipe.pointerId !== pointerId || providerScreenSwipe.source !== source) return;
          const wasActive = providerScreenSwipe.active;
          providerScreenSwipe = null;
          if (wasActive) {
            window.setTimeout(() => { suppressNextCardClick = false; }, 80);
          }
        }

        if (stageEl && window.PointerEvent) {
          stageEl.addEventListener('pointerdown', (e) => {
            if (e.pointerType === 'touch') lastProviderPointerTouchAt.value = Date.now();
            beginProviderSwipeAt(e.clientX, e.clientY, e.target, e.pointerId, 'pointer');
            if (providerScreenSwipe && stageEl.setPointerCapture) {
              try { stageEl.setPointerCapture(e.pointerId); } catch (_) {}
            }
          });
          window.addEventListener('pointermove', (e) => {
            moveProviderSwipeTo(e.clientX, e.clientY, e, e.pointerId, 'pointer');
          }, { passive: false });
          window.addEventListener('pointerup', (e) => {
            endProviderSwipe(e.pointerId, 'pointer');
            if (stageEl.releasePointerCapture) {
              try { stageEl.releasePointerCapture(e.pointerId); } catch (_) {}
            }
          });
          window.addEventListener('pointercancel', (e) => endProviderSwipe(e.pointerId, 'pointer'));
        }
        if (stageEl) {
          stageEl.addEventListener('touchstart', (e) => {
            if (Date.now() - lastProviderPointerTouchAt.value < 700) return;
            const touch = e.touches && e.touches[0];
            if (!touch) return;
            beginProviderSwipeAt(touch.clientX, touch.clientY, e.target, 'touch', 'touch');
          }, { passive: true });
          window.addEventListener('touchmove', (e) => {
            const touch = e.touches && e.touches[0];
            if (!touch) return;
            moveProviderSwipeTo(touch.clientX, touch.clientY, e, 'touch', 'touch');
          }, { passive: false });
          window.addEventListener('touchend', () => endProviderSwipe('touch', 'touch'));
          window.addEventListener('touchcancel', () => endProviderSwipe('touch', 'touch'));
        }
        if (providersEl) {
          providersEl.addEventListener('scroll', updateScrollIndicators, { passive: true });
          providersEl.addEventListener('wheel', (e) => {
            if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
            e.preventDefault();
            providersEl.scrollBy({ left: e.deltaY, behavior: 'smooth' });
          }, { passive: false });
        }
        if (scrollLeftBtn) {
          scrollLeftBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            if (providersEl) providersEl.scrollBy({ left: -246, behavior: 'smooth' });
          });
        }
        if (scrollRightBtn) {
          scrollRightBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            if (providersEl) providersEl.scrollBy({ left: 246, behavior: 'smooth' });
          });
        }

        function renderValueToggle() {
          if (!valueToggle) return;
          for (const btn of valueToggle.querySelectorAll('button')) {
            btn.classList.toggle('active', btn.dataset.mode === displayMode);
            btn.setAttribute('aria-pressed', btn.dataset.mode === displayMode ? 'true' : 'false');
          }
        }
        if (valueToggle) {
          valueToggle.addEventListener('click', (e) => {
            const btn = e.target.closest('button');
            if (!btn) return;
            displayMode = btn.dataset.mode;
            localStorage.setItem('obb_displayMode', displayMode);
            renderValueToggle();
            poll();
          });
        }

        function showDetail(p) {
          if (!detailOverlay || !detailContent) return;
          detailContent.innerHTML = '';
          detailOverlay.classList.add('active');
          if (detailCard) detailCard.style.setProperty('--card-accent', p.accentHex ? '#' + p.accentHex : 'var(--primary)');

          const header = document.createElement('div');
          header.className = 'detail-header';
          const logo = document.createElement('div');
          logo.className = 'logo';
          logo.innerHTML = p.logoSVG || '';
          const title = document.createElement('div');
          title.className = 'name';
          title.textContent = p.name;
          const pill = document.createElement('span');
          pill.className = 'pill tone-' + (p.statusTone || 'mercury');
          pill.textContent = p.statusPill || 'live';
          header.appendChild(logo);
          header.appendChild(title);
          header.appendChild(pill);
          detailContent.appendChild(header);

          if (p.hasQuotaData !== false) {
            if (p.buckets && p.buckets.length > 0) {
              const sec = document.createElement('div');
              sec.className = 'detail-section';
              const h3 = document.createElement('h3');
              h3.textContent = 'Quota';
              sec.appendChild(h3);
              p.buckets.forEach(b => {
                const row = document.createElement('div');
                row.className = 'detail-row';
                const label = document.createElement('span');
                label.className = 'label';
                label.textContent = b.name || '';
                const value = document.createElement('span');
                value.className = 'value';
                value.textContent = b.headlineValue || (b.percent + '%');
                row.appendChild(label);
                row.appendChild(value);
                sec.appendChild(row);
                if (b.percent != null) {
                  const bar = document.createElement('div');
                  bar.className = 'detail-bar';
                  const fill = document.createElement('div');
                  fill.className = 'fill';
                  if (p.accentHex) fill.style.background = '#' + p.accentHex;
                  fill.style.width = Math.min(Math.max(b.percent, 0), 100) + '%';
                  bar.appendChild(fill);
                  sec.appendChild(bar);
                }
                if (b.resetsLabel) {
                  const reset = document.createElement('div');
                  reset.style.cssText = 'font-size:11px;color:var(--text-3);padding-top:2px;';
                  reset.textContent = b.resetsLabel;
                  sec.appendChild(reset);
                }
              });
              detailContent.appendChild(sec);
            }
            if (p.accounts && p.accounts.length > 0) {
              const sec = document.createElement('div');
              sec.className = 'detail-section';
              const h3 = document.createElement('h3');
              h3.textContent = 'Accounts';
              sec.appendChild(h3);
              p.accounts.forEach(a => {
                const row = document.createElement('div');
                row.className = 'detail-account';
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
                sec.appendChild(row);
                // Per-account quota buckets
                if (a.buckets && a.buckets.length > 0) {
                  a.buckets.forEach(b => {
                    const bRow = document.createElement('div');
                    bRow.className = 'detail-row';
                    bRow.style.paddingLeft = '22px';
                    const bLabel = document.createElement('span');
                    bLabel.className = 'label';
                    bLabel.textContent = b.name || '';
                    const bValue = document.createElement('span');
                    bValue.className = 'value';
                    bValue.textContent = b.headlineValue || (b.percent + '%');
                    bRow.appendChild(bLabel);
                    bRow.appendChild(bValue);
                    sec.appendChild(bRow);
                    if (b.percent != null) {
                      const bar = document.createElement('div');
                      bar.className = 'detail-bar';
                      bar.style.marginLeft = '22px';
                      const fill = document.createElement('div');
                      fill.className = 'fill';
                      if (p.accentHex) fill.style.background = '#' + p.accentHex;
                      fill.style.width = Math.min(Math.max(b.percent, 0), 100) + '%';
                      bar.appendChild(fill);
                      sec.appendChild(bar);
                    }
                    if (b.resetsLabel) {
                      const reset = document.createElement('div');
                      reset.style.cssText = 'font-size:11px;color:var(--text-3);padding-top:2px;padding-left:22px;';
                      reset.textContent = b.resetsLabel;
                      sec.appendChild(reset);
                    }
                  });
                } else if (a.percent != null && a.percent > 0) {
                  const pctRow = document.createElement('div');
                  pctRow.style.cssText = 'font-size:11px;color:var(--text-3);padding-left:22px;';
                  pctRow.textContent = a.percent + '% used';
                  sec.appendChild(pctRow);
                }
              });
              detailContent.appendChild(sec);
            }
          } else {
            if (p.burnRates && p.burnRates.length > 0) {
              const sec = document.createElement('div');
              sec.className = 'detail-section';
              const h3 = document.createElement('h3');
              h3.textContent = 'Burn History';
              sec.appendChild(h3);
              p.burnRates.forEach(r => {
                const row = document.createElement('div');
                row.className = 'detail-row';
                const label = document.createElement('span');
                label.className = 'label';
                label.textContent = r.windowLabel || '';
                const value = document.createElement('span');
                value.className = 'value';
                value.textContent = displayMode === 'currency' ? (r.cost || '—') : (r.tokens || '—');
                row.appendChild(label);
                row.appendChild(value);
                sec.appendChild(row);
                if (r.runs) {
                  const sub = document.createElement('div');
                  sub.style.cssText = 'font-size:11px;color:var(--text-3);';
                  sub.textContent = r.runs;
                  sec.appendChild(sub);
                }
              });
              detailContent.appendChild(sec);
            }
          }

          if (p.runsLabel || p.costLabel || p.tokenTotal) {
            const sec = document.createElement('div');
            sec.className = 'detail-section';
            const h3 = document.createElement('h3');
            h3.textContent = 'Totals';
            sec.appendChild(h3);
            if (p.runsLabel) {
              const row = document.createElement('div');
              row.className = 'detail-row';
              const label = document.createElement('span');
              label.className = 'label';
              label.textContent = 'Runs';
              const value = document.createElement('span');
              value.className = 'value';
              value.textContent = p.runsLabel;
              row.appendChild(label);
              row.appendChild(value);
              sec.appendChild(row);
            }
            if (p.costLabel) {
              const row = document.createElement('div');
              row.className = 'detail-row';
              const label = document.createElement('span');
              label.className = 'label';
              label.textContent = 'Cost';
              const value = document.createElement('span');
              value.className = 'value';
              value.textContent = p.costLabel;
              row.appendChild(label);
              row.appendChild(value);
              sec.appendChild(row);
            }
            if (p.tokenTotal) {
              const row = document.createElement('div');
              row.className = 'detail-row';
              const label = document.createElement('span');
              label.className = 'label';
              label.textContent = 'Tokens';
              const value = document.createElement('span');
              value.className = 'value';
              value.textContent = p.tokenTotal;
              row.appendChild(label);
              row.appendChild(value);
              sec.appendChild(row);
            }
            detailContent.appendChild(sec);
          }
        }

        function closeDetail() {
          if (detailOverlay) detailOverlay.classList.remove('active');
        }
        if (detailClose) detailClose.addEventListener('click', closeDetail);
        if (detailOverlay) {
          detailOverlay.addEventListener('click', (e) => {
            if (e.target === detailOverlay) closeDetail();
          });
        }
        document.addEventListener('keydown', (e) => {
          if (e.key === 'Escape' && detailOverlay && detailOverlay.classList.contains('active')) {
            closeDetail();
          }
        });
    """##
}
