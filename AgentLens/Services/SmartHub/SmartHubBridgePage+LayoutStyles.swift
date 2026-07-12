import Foundation

extension SmartHubBridgePage {

    static let htmlLayoutStyles: String = ##"""
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
          min-width: 0;
        }
        .scroll-btn {
          position: absolute;
          top: 50%;
          transform: translateY(-50%);
          width: 36px;
          height: 56px;
          border: none;
          border-radius: 10px;
          background: rgba(255,255,255,0.08);
          color: var(--text-2);
          font-size: 22px;
          font-weight: 700;
          cursor: pointer;
          z-index: 3;
          display: none;
          align-items: center;
          justify-content: center;
          font-family: inherit;
          backdrop-filter: blur(4px);
          -webkit-backdrop-filter: blur(4px);
        }
        .scroll-btn.visible {
          display: flex;
        }
        .scroll-btn.scroll-left { left: 4px; }
        .scroll-btn.scroll-right { right: 4px; }
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
        .stage.voice-pulse .brand-logo {
          animation: voicePulse 1.15s ease-out 1;
        }
        .stage.voice-pulse .live-dot {
          background: var(--primary);
          box-shadow: 0 0 0 8px color-mix(in oklab, var(--primary) 18%, transparent);
        }
        @keyframes voicePulse {
          0%   { transform: scale(1); }
          35%  { transform: scale(1.18); filter: drop-shadow(0 0 18px color-mix(in oklab, var(--primary) 70%, transparent)); }
          100% { transform: scale(1); }
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
          font-size: clamp(48px, 12vw, 96px);
          font-weight: 800;
          letter-spacing: -2px;
          color: var(--text-1);
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
          max-width: 100%;
          padding: 0 16px;
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
    """##
}
