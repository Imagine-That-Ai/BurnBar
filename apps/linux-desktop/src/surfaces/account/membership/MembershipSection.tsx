import { useMemo } from 'react';
import { Banner } from '../../../components/Banner.js';
import { SurfaceCard } from '../../../components/SurfaceCard.js';
import { useLaneLoad } from '../../../state/useLaneLoad.js';
import { hasActivePaidMembership, useMembershipStore } from '../../../state/membershipStore.js';
import { useShellStore } from '../../../state/shellStore.js';
import { FoilButton } from './FoilButton.js';
import { FoilCard } from './FoilCard.js';
import { LockedVeil } from './LockedVeil.js';

const PRO_ENTITLEMENTS = [
  { id: 'burnbar_pro', label: 'BurnBar Pro' },
  { id: 'hosted_quota_sync', label: 'Hosted quota sync' },
  { id: 'burnbar_pro_max', label: 'Cloud Pro controls' },
  { id: 'burnbar_ultra', label: 'Ultra allowance' }
];

function renewalLine(renewsAt?: string): string {
  if (!renewsAt) return 'Renewal date unavailable from the daemon.';
  try {
    return `Renews ${new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(renewsAt))}.`;
  } catch {
    return 'Renewal date unavailable from the daemon.';
  }
}

function stateCopy(state?: string, tier?: string): string {
  if (tier === 'pro') return 'Active';
  if (state === 'cancelled') return 'Cancelled';
  if (state === 'paymentFailed') return 'Payment failed';
  if (state === 'offline') return 'Offline';
  return 'Free';
}

export function MembershipSection() {
  const load = useMembershipStore((s) => s.load);
  const startCheckout = useMembershipStore((s) => s.startCheckout);
  const restore = useMembershipStore((s) => s.restore);
  const data = useMembershipStore((s) => s.data);
  const phase = useMembershipStore((s) => s.phase);
  const error = useMembershipStore((s) => s.error);
  const checkoutUrl = useMembershipStore((s) => s.checkoutUrl);
  const externalDestination = useMembershipStore((s) => s.externalDestination);
  const fixtureMode = useShellStore((s) => s.fixtureMode);

  useLaneLoad(load);

  const loading = phase === 'loading';
  const checkoutInFlight = phase === 'checkout-in-flight';
  const portalInFlight = phase === 'portal-in-flight';
  const restoreInFlight = phase === 'restore-in-flight';
  const pro = hasActivePaidMembership(data);
  const entitlementSet = useMemo(() => new Set(data?.entitlements ?? []), [data]);
  const statusText = stateCopy(data?.state, data?.tier);
  const provenance =
    phase === 'offline' || phase === 'capability-absent'
      ? 'offline degraded'
      : fixtureMode
        ? 'fixture transcript'
        : 'live daemon';

  return (
    <SurfaceCard
      title="Membership"
      titleId="account-membership-panel"
      description="Linux uses external Stripe checkout as the StoreKit substitute."
    >
      <div className="membership-section" data-membership-phase={phase}>
        <div className="membership-band" role="status" aria-live="polite" aria-atomic="true">
          <span className={`membership-tier-dot ${pro ? 'membership-tier-dot--pro' : ''}`} aria-hidden="true" />
          <span className="membership-tier-copy">
            <strong>{pro ? 'Cloud Pro member' : 'Free local member'}</strong>
            <span>{loading ? 'Checking daemon membership status…' : `${statusText} · ${renewalLine(data?.renewsAt)}`}</span>
          </span>
        </div>
        <p className="membership-provenance">Data source: {provenance}</p>

        {error ? (
          <Banner tone={phase === 'capability-absent' || phase === 'offline' ? 'ok' : 'degraded'} role={phase === 'error' ? 'alert' : 'status'}>
            {error}
          </Banner>
        ) : null}

        {checkoutInFlight || portalInFlight ? (
          <Banner tone="ok" role="status">
            {externalDestination === 'portal'
              ? 'Stripe billing management opened in your browser.'
              : 'Stripe checkout opened in your browser. Return here and use Check again after completing checkout.'}
            {checkoutUrl ? ` Secure host: ${new URL(checkoutUrl).hostname}.` : ''}
          </Banner>
        ) : null}

        {restoreInFlight ? (
          <Banner tone="ok" role="status">
            Restoring membership through the daemon…
          </Banner>
        ) : null}

        <FoilCard
          eyebrow={pro ? 'OPENBURNBAR CLOUD' : 'PRO FOIL'}
          title={pro ? 'Member' : 'Lift the lid'}
          detail={
            pro
              ? 'Hosted quota refresh, sealed cloud memory, and Cloud Pro capability gates are available to this Linux peer.'
              : 'Upgrade in the browser with Stripe. The Linux shell never embeds checkout or collects payment credentials.'
          }
          active={pro}
        >
          <FoilButton disabled={loading || checkoutInFlight || portalInFlight} onClick={() => void startCheckout()}>
            {checkoutInFlight || portalInFlight ? 'Opening…' : pro ? 'Manage subscription' : 'Open checkout'}
          </FoilButton>
          <FoilButton variant="secondary" disabled={loading || restoreInFlight} onClick={() => void restore()}>
            {restoreInFlight ? 'Restoring…' : 'Restore'}
          </FoilButton>
          <FoilButton variant="secondary" disabled={loading} onClick={() => void load()}>
            Re-check membership
          </FoilButton>
        </FoilCard>

        <div className="membership-entitlements" aria-label="Membership entitlements">
          {PRO_ENTITLEMENTS.map((entitlement) => {
            const active = entitlementSet.has(entitlement.id);
            return (
              <div
                key={entitlement.id}
                className={`membership-entitlement-row ${active ? 'membership-entitlement-row--active' : ''}`}
              >
                <span>{entitlement.label}</span>
                <span>{active ? 'Active' : 'Locked'}</span>
              </div>
            );
          })}
        </div>

        <LockedVeil
          locked={!pro}
          title="Hosted Pro tools are locked"
          detail="Remote MCP, hosted quota refresh, and Cloud Pro controls wait behind verified membership."
          cta="Unlock Pro"
          onUnlock={() => void startCheckout()}
        >
          <div className="membership-pro-preview">
            <button type="button">Hosted Remote MCP</button>
            <button type="button">Refresh quotas from cloud</button>
            <button type="button">Open Cloud Pro controls</button>
          </div>
        </LockedVeil>
      </div>
    </SurfaceCard>
  );
}
