import Foundation

extension SmartHubBridgePage {

    static let htmlCardScript: String = ##"""

        function renderCard(p) {
          const card = document.createElement('article');
          card.className = 'card live';
          card.id = 'card-' + (p.slug || slugify(p.name));
          card.setAttribute('role', 'button');
          card.setAttribute('tabindex', '0');
          card.setAttribute('aria-label', p.name + ' details');
          if (p.accentHex) {
            card.style.setProperty('--card-accent', '#' + p.accentHex);
          }

          // Click / Enter to open detail overlay
          card.addEventListener('click', (e) => {
            if (suppressNextCardClick) {
              e.preventDefault();
              e.stopPropagation();
              suppressNextCardClick = false;
              return;
            }
            showDetail(p);
          });
          card.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              showDetail(p);
            }
          });

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

          // Big number: currency or tokens depending on toggle
          const bigValue = displayMode === 'currency'
            ? (p.tokenTotalCurrency || p.tokenTotal || '')
            : (p.tokenTotal || '');
          if (bigValue) {
            const total = document.createElement('div');
            total.className = 'token-total';
            total.textContent = bigValue;
            card.appendChild(total);

            const tlabel = document.createElement('div');
            tlabel.className = 'token-label';
            tlabel.textContent = displayMode === 'currency' ? 'COST' : (p.tokenTotalLabel || 'TOKENS');
            card.appendChild(tlabel);
          } else {
            const spacer = document.createElement('div');
            spacer.style.height = '6px';
            card.appendChild(spacer);
          }

          if (p.hasQuotaData !== false) {
            // Quota provider: bucket rows + accounts
            const buckets = document.createElement('div');
            buckets.className = 'bucket-list';
            (p.buckets || []).forEach(b => buckets.appendChild(renderBucket(b, p.accentHex)));
            card.appendChild(buckets);

            if (p.accounts && p.accounts.length > 0) {
              card.appendChild(renderAccounts(p.accounts));
            }
          } else {
            // Burn-only provider: burn-rate rows
            const noQuota = document.createElement('div');
            noQuota.className = 'no-quota-label';
            noQuota.textContent = 'Usage';
            card.appendChild(noQuota);

            const burnList = document.createElement('div');
            burnList.className = 'burn-list';
            (p.burnRates || []).forEach(r => burnList.appendChild(renderBurnRow(r)));
            card.appendChild(burnList);
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

        function renderBucket(b, accentHex) {
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
          if (accentHex) fill.style.background = '#' + accentHex;
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

        function renderBurnRow(r) {
          const row = document.createElement('div');
          row.className = 'burn-row';
          const window = document.createElement('span');
          window.className = 'window';
          window.textContent = r.windowLabel || '';
          const right = document.createElement('div');
          right.className = 'right';
          const value = document.createElement('span');
          value.className = 'value';
          value.textContent = displayMode === 'currency' ? (r.cost || '—') : (r.tokens || '—');
          const sub = document.createElement('span');
          sub.className = 'sub';
          sub.textContent = r.runs || '';
          right.appendChild(value);
          right.appendChild(sub);
          row.appendChild(window);
          row.appendChild(right);
          return row;
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
    """##
}
