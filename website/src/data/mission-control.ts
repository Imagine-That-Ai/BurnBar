import manifest from "../../public/mission-control/release.json";
import tokens from "./mission-control-tokens.json";

export interface MissionControlRelease {
  schemaVersion: number;
  state: string;
  product: string;
  version: string | null;
  minimumMacOS: string;
  architectures: string[];
  artifact: { url: string; sha256: string } | null;
  developerIDVerified: boolean;
  notarization: string;
  stapled: boolean;
  publicDownloadVerified: boolean;
  cleanInstallVerified: boolean;
  releaseNotesUrl: string | null;
  verifiedAt: string | null;
}

function isHttpsUrl(value: string | null | undefined): boolean {
  if (!value) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password;
  } catch {
    return false;
  }
}

export function isPublicRelease(release: MissionControlRelease): boolean {
  return (
    release.schemaVersion === 1 &&
    release.state === "published" &&
    Boolean(release.version?.trim()) &&
    Boolean(release.minimumMacOS.trim()) &&
    release.architectures.length > 0 &&
    isHttpsUrl(release.artifact?.url) &&
    Boolean(release.artifact && /^[a-f0-9]{64}$/i.test(release.artifact.sha256)) &&
    release.developerIDVerified &&
    release.notarization === "accepted" &&
    release.stapled &&
    release.publicDownloadVerified &&
    release.cleanInstallVerified &&
    isHttpsUrl(release.releaseNotesUrl) &&
    Boolean(release.verifiedAt && Number.isFinite(Date.parse(release.verifiedAt)))
  );
}

export const MISSION_CONTROL_RELEASE: MissionControlRelease = manifest;
export const MISSION_CONTROL_DOWNLOAD_READY = isPublicRelease(MISSION_CONTROL_RELEASE);

const cssTokens: Record<string, string> = {
  "--mc-pink": tokens.colors.brandPrimary,
  "--mc-orange": tokens.colors.brandSecondary,
  "--mc-canary": tokens.colors.brandTertiary,
  "--mc-ink": tokens.colors.ink,
  "--mc-r-md": `${tokens.radii.md}px`,
  "--mc-r-lg": `${tokens.radii.lg}px`,
  "--mc-r-xl": `${tokens.radii.xl}px`,
  "--mc-r-full": `${tokens.radii.full}px`,
  "--mc-inset": `${tokens.spaceRoles.inset}px`,
  "--mc-section": `${tokens.spaceRoles.section}px`,
  "--mc-cluster": `${tokens.spaceRoles.cluster}px`,
  "--mc-body": `${tokens.typeScale.body.size}px`,
  "--mc-label": `${tokens.typeScale.label.size}px`,
  "--mc-title": `${tokens.typeScale.title.size}px`,
  "--mc-standard": `${tokens.motion.standard.response}s`
};

export const MISSION_CONTROL_STYLE = Object.entries(cssTokens)
  .map(([key, value]) => `${key}:${value}`)
  .join(";");
