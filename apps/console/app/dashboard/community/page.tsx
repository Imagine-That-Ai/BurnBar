"use client";

import * as React from "react";

import { buildCommunityView, lookingGlassExportCopy } from "@/lib/community/viewModel";
import {
  cycleTriState,
  defaultCommunityConsent,
  readLocalCommunityConsent,
  writeLocalCommunityConsent,
} from "@/lib/community/localConsent";
import type { CommunityConsentDoc, CommunityTimeWindow, GeographyTier } from "@/lib/community/types";
import { GEO_TIER_ORDER, TIME_WINDOWS } from "@/lib/community/types";
import { exportLookingGlassBundle, joinCommunity, revokeCommunityParticipation } from "@/lib/api";
import { buildJoinCommunityRequest } from "@/lib/community/joinPayload";
import { resolveBrowserCityKey } from "@/lib/community/browserCityLocation";
import { cityKeyFromManualCityInput } from "@/lib/community/geoCityKey";
import { deviceGeoKeys } from "@/lib/community/joinPayload";
import { useBackdrop } from "@/lib/useBackdrop";
import { useCommunityLiveData } from "@/lib/community/useCommunityLiveData";

function tierTitle(tier: GeographyTier): string {
  switch (tier) {
    case "city":
      return "City";
    case "region":
      return "Region";
    case "country":
      return "Country";
    default:
      return "World";
  }
}

export default function CommunityDashboardPage() {
  const { kernelId } = useBackdrop();
  const [consent, setConsent] = React.useState<CommunityConsentDoc>(() => readLocalCommunityConsent());
  const [window, setWindow] = React.useState<CommunityTimeWindow>("30d");
  const [status, setStatus] = React.useState("");
  const [syncing, setSyncing] = React.useState(false);
  const [lookingGlassExportState, setLookingGlassExportState] = React.useState<"idle" | "ready" | "error">("idle");
  const [lookingGlassExportUrl, setLookingGlassExportUrl] = React.useState("");

  const liveData = useCommunityLiveData(window);
  const view = React.useMemo(
    () => buildCommunityView(consent, window, { shareSnapshot: liveData.shareSnapshot, leaderboards: liveData.leaderboards }),
    [consent, window, liveData.shareSnapshot, liveData.leaderboards],
  );
  const lookingGlassExport = React.useMemo(
    () => (lookingGlassExportState === "idle" ? view.lookingGlassExport : lookingGlassExportCopy(lookingGlassExportState)),
    [lookingGlassExportState, view.lookingGlassExport],
  );

  const frostStyle = { "--lg-frost": "0.35" } as React.CSSProperties;

  const persist = (next: CommunityConsentDoc) => {
    setConsent(next);
    writeLocalCommunityConsent(next);
  };

  return (
    <div className="lg-dashboard" style={frostStyle} data-kernel={kernelId}>
      <header className="lg-bar mb-token-6">
        <span className="eyebrow">Community</span>
        <h1 className="font-display text-2xl text-content-bright">Anonymous rankings</h1>
        <p className="text-sm text-content-mute">
          Consent-first sharing — below k=10 we show no individual burner data.
        </p>
      </header>

      {view.showInvite ? (
        <div className="lg-bar mb-token-4 text-sm text-content-mute">
          Opt in to L2 community rankings to preview leaderboards. Unset and declined stay dark.
        </div>
      ) : null}
      {view.isPreviewData ? (
        <div className="lg-bar mb-token-4 text-sm text-content-mute">
          {view.statusMessage}
        </div>
      ) : null}
      {liveData.status === "loading" ? (
        <div className="lg-bar mb-token-4 text-sm text-content-mute">
          Syncing signed-in Community data…
        </div>
      ) : null}
      {liveData.status === "error" ? (
        <div className="lg-bar mb-token-4 text-sm text-content-mute">
          Community sync unavailable: {liveData.errorMessage}
        </div>
      ) : null}

      <section className="lg-card mb-token-4 p-token-4">
        <h2 className="font-display text-lg">Personal hero</h2>
        <p className="font-mono text-2xl">{view.hero.tokens.toLocaleString()} tokens</p>
        <p className="text-content-mute">${view.hero.costUSD.toFixed(2)} estimated · Δ {view.hero.trendDeltaPct}%</p>
        <p className="text-sm text-content-mute">{view.hero.modelMixSummary}</p>
        {view.isPreviewData ? (
          <p className="text-xs text-content-mute">Preview — not live usage or rankings.</p>
        ) : null}
        <p className="text-sm text-content-mute">{view.cityConfidenceCopy}</p>
      </section>

      <section className="lg-bar mb-token-4 flex flex-wrap gap-token-2">
        {TIME_WINDOWS.map((w) => (
          <button
            key={w.id}
            type="button"
            className={`btn-outline ${window === w.id ? "opacity-100" : "opacity-70"}`}
            onClick={() => setWindow(w.id)}
          >
            {w.label}
          </button>
        ))}
      </section>

      <section className="mb-token-4 grid gap-token-3 md:grid-cols-2">
        {view.leaderboards.map((board) => (
          <article key={board.tier} className="lg-card p-token-4">
            <h3 className="font-display">
              {tierTitle(board.tier as GeographyTier)} · {board.geoKey}
            </h3>
            {board.belowThreshold ? (
              <p className="text-sm text-content-mute">
                Needs {board.kThreshold} more burners. entries=[] — no individual data below threshold.
              </p>
            ) : (
              <ul className="mt-token-2 space-y-token-1 text-sm">
                {board.entries.map((e) => (
                  <li key={e.anonId}>
                    #{e.rank} {e.handle ?? e.anonId} · {e.totalTokens.toLocaleString()} tok · ${e.costUSD.toFixed(2)}
                  </li>
                ))}
              </ul>
            )}
          </article>
        ))}
      </section>

      <section className="lg-card mb-token-4 p-token-4">
        <h3>Percentile strip</h3>
        <p className="font-mono text-sm">
          p50 {view.percentiles.p50.toLocaleString()} · p75 {view.percentiles.p75.toLocaleString()} · p90{" "}
          {view.percentiles.p90.toLocaleString()} · p99 {view.percentiles.p99.toLocaleString()}
        </p>
      </section>

      <section className="lg-card mb-token-4 p-token-4">
        <h3>Peer comparison (anonymized cohort)</h3>
        <p className="text-sm text-content-mute">
          {view.peerCohortTokens.length === 0
            ? view.isPreviewData
              ? "Preview only — cohort chart stays empty until live boards sync."
              : "Unlocks when a tier clears k-anonymity."
            : view.peerCohortTokens.map((v) => v.toLocaleString()).join(" · ")}
        </p>
      </section>

      <section className="lg-card mb-token-4 p-token-4">
        <h3>Purpose breakdown</h3>
        <ul className="text-sm">
          {view.purposeBreakdown.map((s) => (
            <li key={s.category} className="flex justify-between">
              <span>{s.category}</span>
              <span>{Math.round(s.share * 100)}%</span>
            </li>
          ))}
        </ul>
      </section>

      <section className="lg-card p-token-4">
        <h3>Consent center</h3>
        <p className="mb-token-3 text-sm text-content-mute">{view.consentPreview}</p>
        {status ? <p className="mb-token-3 text-sm text-content-mute">{status}</p> : null}
        <p className="mb-token-3 text-sm text-content-mute">{lookingGlassExport.message}</p>
        {lookingGlassExportUrl ? (
          <a className="btn-outline mb-token-3 inline-flex" href={lookingGlassExportUrl}>
            Download Looking Glass export
          </a>
        ) : null}
        <div className="flex flex-wrap gap-token-2">
          {(
            [
              ["L1 analytics", "l1Analytics"],
              ["L2 rankings", "l2Rankings"],
              ["L3 looking glass", "l3LookingGlass"],
              ["Location", "locationConsent"],
            ] as const
          ).map(([label, key]) => (
            <button
              key={key}
              type="button"
              className="btn-outline"
              onClick={() =>
                persist({
                  ...consent,
                  [key]: cycleTriState(consent[key]),
                })
              }
            >
              {label}: {consent[key]}
            </button>
          ))}
        </div>
        <div className="mt-token-3 flex flex-wrap gap-token-2">
          {GEO_TIER_ORDER.map((tier) => (
            <button
              key={tier}
              type="button"
              className="btn-outline"
              onClick={() =>
                persist({
                  ...consent,
                  l2Tiers: {
                    ...consent.l2Tiers,
                    [tier]: cycleTriState(consent.l2Tiers[tier]),
                  },
                })
              }
            >
              {tierTitle(tier)} tier: {consent.l2Tiers[tier]}
            </button>
          ))}
        </div>
        {consent.l2Tiers.city === "granted" && consent.locationConsent === "granted" ? (
          <label className="mt-token-3 flex max-w-md flex-col gap-token-2 text-sm">
            <span className="text-content-mute">Your city (browser location or manual fallback)</span>
            <input
              type="text"
              className="btn-outline w-full px-token-3 py-token-2"
              value={consent.manualCityInput ?? ""}
              placeholder="e.g. San Francisco"
              onChange={(e) => persist({ ...consent, manualCityInput: e.target.value })}
            />
          </label>
        ) : null}
        <button
          type="button"
          className="btn-outline mt-token-4"
          disabled={syncing}
          onClick={() => {
            void (async () => {
              setSyncing(true);
              try {
                let cityKey: string | undefined;
                if (consent.l2Tiers.city === "granted" && consent.locationConsent === "granted") {
                  cityKey = await resolveBrowserCityKey();
                  if (!cityKey && consent.manualCityInput?.trim()) {
                    const { timezone, locale } = deviceGeoKeys();
                    cityKey = cityKeyFromManualCityInput(consent.manualCityInput, timezone, locale);
                  }
                }
                await joinCommunity(buildJoinCommunityRequest(consent, { cityKey }));
                setStatus("Community preferences saved.");
              } catch {
                setStatus("Could not sync community preferences. Sign in and try again.");
              } finally {
                setSyncing(false);
              }
            })();
          }}
        >
          Save &amp; sync to community
        </button>
        {consent.l3LookingGlass === "granted" ? (
          <button
            type="button"
            className="btn-outline mt-token-4"
            disabled={syncing}
            onClick={() => {
              void (async () => {
                setSyncing(true);
                try {
                  const exportResult = await exportLookingGlassBundle("jsonl");
                  setLookingGlassExportUrl(exportResult.downloadUrl);
                  setLookingGlassExportState("ready");
                  setStatus(`Looking Glass export contains ${exportResult.traceCount} trace(s).`);
                } catch {
                  setLookingGlassExportUrl("");
                  setLookingGlassExportState("error");
                  setStatus("Could not export Looking Glass bundle. Consent, traces, or sign-in may be missing.");
                } finally {
                  setSyncing(false);
                }
              })();
            }}
          >
            Export Looking Glass bundle
          </button>
        ) : null}
        <button
          type="button"
          className="btn-outline mt-token-4"
          onClick={() => {
            void (async () => {
              setSyncing(true);
              try {
                await revokeCommunityParticipation();
                const d = defaultCommunityConsent();
                persist({
                  ...d,
                  l1Analytics: "declined",
                  l2Rankings: "declined",
                  l3LookingGlass: "declined",
                  locationConsent: "declined",
                  l2Tiers: { world: "declined", country: "declined", region: "declined", city: "declined" },
                });
                setStatus("Participation revoked on this device and the server.");
              } catch {
                setStatus("Could not revoke server participation. Sign in and try again.");
              } finally {
                setSyncing(false);
              }
            })();
          }}
        >
          Pause / revoke participation
        </button>
        {status ? <p className="mt-token-2 text-sm text-content-mute">{status}</p> : null}
      </section>
    </div>
  );
}