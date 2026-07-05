import { ProviderGlyphs } from '../components/ProviderGlyphs.js';
import { DaemonDataSection } from './DaemonDataSection.js';

export function ProvidersSurface() {
  return (
    <>
      <ProviderGlyphs />
      <DaemonDataSection route="providers" label="Providers & models" />
    </>
  );
}
