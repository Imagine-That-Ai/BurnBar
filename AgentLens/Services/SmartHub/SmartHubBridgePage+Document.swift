import Foundation

extension SmartHubBridgePage {

    static let htmlDocumentStart: String = ##"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
      <title>OpenBurnBar — Quota</title>
      <style>
    """##

    static let htmlBodyMarkup: String = ##"""
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
          <button class="scroll-btn scroll-left" id="scrollLeft" type="button" aria-label="Scroll left">‹</button>
          <button class="scroll-btn scroll-right" id="scrollRight" type="button" aria-label="Scroll right">›</button>
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
    """##

    static let htmlDocumentEnd: String = ##"""
      </script>
    </body>
    </html>
    """##
}
