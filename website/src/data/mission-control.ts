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

/** One piece of distribution evidence a public download must carry. */
export interface ReleaseCheck {
  id: string;
  label: string;
  done: boolean;
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

/**
 * Every condition the public download depends on, in the order a release
 * actually earns them. The page renders this list as the release status, and
 * `isPublicRelease` is defined as "every check is done", so the visible
 * checklist and the download gate cannot drift apart.
 */
export function releaseEvidence(release: MissionControlRelease): ReleaseCheck[] {
  return [
    {
      id: "manifest",
      label: "Published release manifest",
      done: release.schemaVersion === 1 && release.state === "published"
    },
    {
      id: "version",
      label: "Version and supported Macs",
      done:
        Boolean(release.version?.trim()) &&
        Boolean(release.minimumMacOS.trim()) &&
        release.architectures.length > 0
    },
    {
      id: "artifact",
      label: "HTTPS download with SHA-256",
      done:
        isHttpsUrl(release.artifact?.url) &&
        Boolean(release.artifact && /^[a-f0-9]{64}$/i.test(release.artifact.sha256))
    },
    { id: "signature", label: "Developer ID signature", done: release.developerIDVerified },
    {
      id: "notarization",
      label: "Apple notarization accepted",
      done: release.notarization === "accepted"
    },
    { id: "stapled", label: "Notarization ticket stapled", done: release.stapled },
    {
      id: "public-download",
      label: "Public download checked",
      done: release.publicDownloadVerified
    },
    {
      id: "clean-install",
      label: "Clean installation checked",
      done: release.cleanInstallVerified
    },
    {
      id: "notes",
      label: "Release notes and verification date",
      done:
        isHttpsUrl(release.releaseNotesUrl) &&
        Boolean(release.verifiedAt && Number.isFinite(Date.parse(release.verifiedAt)))
    }
  ];
}

export function isPublicRelease(release: MissionControlRelease): boolean {
  return releaseEvidence(release).every((check) => check.done);
}

const ARCHITECTURE_NAMES: Record<string, string> = {
  arm64: "Apple silicon",
  x86_64: "Intel"
};

/** "arm64", "x86_64" → "Apple silicon and Intel". Unknown names pass through. */
export function describeArchitectures(architectures: string[]): string {
  const names = architectures.map((arch) => ARCHITECTURE_NAMES[arch] ?? arch);
  if (names.length <= 1) return names.join("");
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
}

export const MISSION_CONTROL_RELEASE: MissionControlRelease = manifest;
export const MISSION_CONTROL_DOWNLOAD_READY = isPublicRelease(MISSION_CONTROL_RELEASE);
export const MISSION_CONTROL_EVIDENCE = releaseEvidence(MISSION_CONTROL_RELEASE);
export const MISSION_CONTROL_VOICE = tokens.voice;
export const MISSION_CONTROL_META = tokens.meta;

// ─── Contrast-safe foreground variants ──────────────────────────────────────
// The brand accents are pastels. They read beautifully as fills and on the dark
// base, but pink, orange and canary all fail WCAG AA as small text on the light
// base. Instead of hand-picking parallel hex values, derive the darkest-needed
// variant from the token itself: mix toward `ink` until the text clears 4.5:1
// against the light raised surface (the dimmest light background on the page).

type Rgb = [number, number, number];

function parseHex(hex: string): Rgb {
  const value = hex.replace("#", "");
  const channel = (offset: number) => parseInt(value.slice(offset, offset + 2), 16);
  return [channel(0), channel(2), channel(4)];
}

function mapRgb(rgb: Rgb, fn: (channel: number, index: number) => number): Rgb {
  return [fn(rgb[0], 0), fn(rgb[1], 1), fn(rgb[2], 2)];
}

function toHex(rgb: Rgb): string {
  return `#${rgb.map((channel) => Math.round(channel).toString(16).padStart(2, "0")).join("")}`.toUpperCase();
}

function luminance(hex: string): number {
  const [r, g, b] = mapRgb(parseHex(hex), (channel) => {
    const c = channel / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrastRatio(a: string, b: string): number {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/** Mix `color` toward `toward` in 1% steps until it reaches `minRatio` on `background`. */
export function deepen(
  color: string,
  background: string,
  minRatio = 4.5,
  toward = tokens.colors.ink
): string {
  const from = parseHex(color);
  const to = parseHex(toward);
  for (let step = 0; step <= 100; step++) {
    const t = step / 100;
    const candidate = toHex(
      mapRgb(from, (channel, i) => channel + ((to[i] ?? channel) - channel) * t)
    );
    if (contrastRatio(candidate, background) >= minRatio) return candidate;
  }
  return toward;
}

const { colors, radii, spaceRoles, typeScale, motion, elevation, measure, gradients, mark } =
  tokens;

export const MISSION_CONTROL_DEEP = {
  pink: deepen(colors.brandPrimary, colors.lightRaised),
  orange: deepen(colors.brandSecondary, colors.lightRaised),
  canary: deepen(colors.brandTertiary, colors.lightRaised)
};

function shadow(level: keyof typeof elevation): string {
  const { y, blur, alpha } = elevation[level];
  return `0 ${y}px ${blur}px rgb(0 0 0 / ${alpha})`;
}

// Spring response → CSS duration. A critically damped spring (damping ≥ 0.8)
// settles without overshoot, which a strong ease-out curve approximates.
const cssTokens: Record<string, string> = {
  // Brand and neutrals
  "--mc-pink": colors.brandPrimary,
  "--mc-orange": colors.brandSecondary,
  "--mc-canary": colors.brandTertiary,
  "--mc-assemble": mark.assembleMid,
  "--mc-pink-deep": MISSION_CONTROL_DEEP.pink,
  "--mc-orange-deep": MISSION_CONTROL_DEEP.orange,
  "--mc-canary-deep": MISSION_CONTROL_DEEP.canary,
  "--mc-mint": colors.mint,
  "--mc-ink": colors.ink,
  "--mc-light-base": colors.lightBase,
  "--mc-light-raised": colors.lightRaised,
  "--mc-light-pearl": colors.pearlLight,
  "--mc-light-hairline": colors.hairlineLight,
  "--mc-light-secondary": colors.labelSecondaryLight,
  "--mc-dark-base": colors.darkBase,
  "--mc-dark-raised": colors.darkRaised,
  "--mc-dark-pearl": colors.pearlDark,
  "--mc-dark-hairline": colors.hairlineDark,
  "--mc-dark-secondary": colors.labelSecondaryDark,
  "--mc-gradient": `linear-gradient(120deg, ${gradients.stack.join(", ")})`,
  "--mc-gradient-icon": `linear-gradient(135deg, ${gradients.iconDiagonal.join(", ")})`,
  // Shape and elevation
  "--mc-r-sm": `${radii.sm}px`,
  "--mc-r-md": `${radii.md}px`,
  "--mc-r-lg": `${radii.lg}px`,
  "--mc-r-xl": `${radii.xl}px`,
  "--mc-r-full": `${radii.full}px`,
  "--mc-shadow-1": shadow("1"),
  "--mc-shadow-2": shadow("2"),
  // Space
  "--mc-row": `${spaceRoles.row}px`,
  "--mc-cluster": `${spaceRoles.cluster}px`,
  "--mc-control": `${spaceRoles.control}px`,
  "--mc-inset": `${spaceRoles.inset}px`,
  "--mc-page": `${spaceRoles.page}px`,
  "--mc-section": `${spaceRoles.section}px`,
  "--mc-empty": `${spaceRoles.empty}px`,
  // Measures
  "--mc-measure": `${measure.conversationMax}px`,
  "--mc-sidebar": `${measure.sidebarIdeal}px`,
  "--mc-context": `${measure.workspaceRailIdeal}px`,
  "--mc-icon-rail": `${measure.iconRail}px`,
  "--mc-places-bar": `${measure.placesBarLabeled}px`,
  // Type
  "--mc-display": `${typeScale.display.size}px`,
  "--mc-display-track": `${typeScale.display.tracking}px`,
  "--mc-title": `${typeScale.title.size}px`,
  "--mc-title-track": `${typeScale.title.tracking}px`,
  "--mc-headline": `${typeScale.headline.size}px`,
  "--mc-headline-track": `${typeScale.headline.tracking}px`,
  "--mc-body": `${typeScale.body.size}px`,
  "--mc-label": `${typeScale.label.size}px`,
  "--mc-label-track": `${typeScale.label.tracking}px`,
  "--mc-caption": `${typeScale.caption.size}px`,
  "--mc-caption-track": `${typeScale.caption.tracking}px`,
  "--mc-code": `${typeScale.code.size}px`,
  // Motion
  "--mc-snappy": `${motion.snappy.response}s`,
  "--mc-standard": `${motion.standard.response}s`,
  "--mc-gentle": `${motion.gentle.response}s`,
  "--mc-fade": `${motion.fadeMs[1]}ms`,
  "--mc-ease": "cubic-bezier(0.22, 1, 0.36, 1)"
};

export const MISSION_CONTROL_STYLE = Object.entries(cssTokens)
  .map(([key, value]) => `${key}:${value}`)
  .join(";");
