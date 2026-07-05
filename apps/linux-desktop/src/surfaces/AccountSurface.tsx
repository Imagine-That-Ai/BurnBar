import { FailureStateList } from '../components/FailureStateList.js';
import { SystemStatusSection } from './SystemStatusSection.js';

const ACCOUNT_CASES = [
  {
    id: 'login-required',
    title: 'Signed out',
    recovery: 'Use lower-trust Linux identity for cloud sync; local SQLite remains canonical while signed out.'
  },
  {
    id: 'sync-paused',
    title: 'Sync paused',
    recovery: 'Encrypted private rows stay local until you opt back in.'
  },
  {
    id: 'quota-exhausted',
    title: 'Quota exhausted',
    recovery: 'Switch providers, lower model tier, or wait for the reset window.'
  }
];

export function AccountSurface() {
  return (
    <>
      <SystemStatusSection />
      <FailureStateList cases={ACCOUNT_CASES} />
    </>
  );
}
