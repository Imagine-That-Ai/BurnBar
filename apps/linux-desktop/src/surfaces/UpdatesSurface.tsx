import { FailureStateList } from '../components/FailureStateList.js';

const UPDATE_CASES = [
  {
    id: 'channel-unavailable',
    title: 'Update channel unavailable',
    recovery: 'Use the package manager transcript in Support; release packaging is handled outside this shell lane.'
  },
  {
    id: 'restart-required',
    title: 'Restart required',
    recovery: 'Quit from tray or Support after the package manager finishes replacing binaries.'
  }
];

export function UpdatesSurface() {
  return <FailureStateList cases={UPDATE_CASES} />;
}
