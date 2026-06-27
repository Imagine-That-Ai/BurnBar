/**
 * The catalog of dashboard cards: id → title, blurb, icon, default size, and
 * the body component. Single source the wizard lists, the grid renders, and the
 * persistence layer validates against. Every card binds to live Firestore
 * usage (users/{uid}/usage_rollups + quota_snapshots + billing/allowances).
 */

import {
  Activity,
  Boxes,
  Coins,
  Cpu,
  Flame,
  Gauge,
  LineChart,
  MonitorSmartphone,
  Orbit,
  Wand2,
  type LucideIcon,
} from "lucide-react";
import type { ComponentType } from "react";

import { KERNEL_META } from "@/lib/gl/engine/registry";
import type { CardProps } from "./cardTypes";
import type { GridRect } from "./gridMath";
import {
  LAYOUT_SCHEMA_VERSION,
  type DashboardAppearance,
  type DashboardLayoutItem,
  type DashboardState,
} from "./layoutStore";
import { BurnTotalCard } from "./cards/BurnTotalCard";
import { DevicesCard } from "./cards/DevicesCard";
import { FormationCard } from "./cards/FormationCard";
import { ModelsCard } from "./cards/ModelsCard";
import { ProviderLimitsCard } from "./cards/ProviderLimitsCard";
import { ProviderListCard } from "./cards/ProviderListCard";
import { RequestsCard } from "./cards/RequestsCard";
import { TokensCard } from "./cards/TokensCard";
import { UsageTrendCard } from "./cards/UsageTrendCard";
import { WandCard } from "./cards/WandCard";

export type CardId =
  | "burn"
  | "usage-trend"
  | "tokens"
  | "requests"
  | "wand"
  | "providers"
  | "models"
  | "limits"
  | "devices"
  | "formation";

export interface CardDef {
  id: CardId;
  title: string;
  /** Wizard description. */
  blurb: string;
  icon: LucideIcon;
  defaultSize: { w: number; h: number };
  component: ComponentType<CardProps>;
}

export const CARD_DEFS: CardDef[] = [
  {
    id: "burn",
    title: "Burn total",
    blurb: "Total spend for the window, with a usage trend.",
    icon: Flame,
    defaultSize: { w: 4, h: 3 },
    component: BurnTotalCard,
  },
  {
    id: "usage-trend",
    title: "Tokens / day",
    blurb: "Daily token usage across the window.",
    icon: LineChart,
    defaultSize: { w: 8, h: 3 },
    component: UsageTrendCard,
  },
  {
    id: "tokens",
    title: "Tokens",
    blurb: "Total tokens processed.",
    icon: Coins,
    defaultSize: { w: 3, h: 2 },
    component: TokensCard,
  },
  {
    id: "requests",
    title: "Requests",
    blurb: "Total API requests and average size.",
    icon: Activity,
    defaultSize: { w: 3, h: 2 },
    component: RequestsCard,
  },
  {
    id: "wand",
    title: "The Wand",
    blurb: "Fusion search allowance this month.",
    icon: Wand2,
    defaultSize: { w: 6, h: 2 },
    component: WandCard,
  },
  {
    id: "providers",
    title: "Provider spend",
    blurb: "Spend by provider, ranked.",
    icon: Boxes,
    defaultSize: { w: 4, h: 4 },
    component: ProviderListCard,
  },
  {
    id: "models",
    title: "Models",
    blurb: "Spend by model, ranked.",
    icon: Cpu,
    defaultSize: { w: 4, h: 4 },
    component: ModelsCard,
  },
  {
    id: "limits",
    title: "Provider limits",
    blurb: "Live provider quota — used vs limit.",
    icon: Gauge,
    defaultSize: { w: 4, h: 4 },
    component: ProviderLimitsCard,
  },
  {
    id: "devices",
    title: "Devices",
    blurb: "Token usage by device.",
    icon: MonitorSmartphone,
    defaultSize: { w: 6, h: 3 },
    component: DevicesCard,
  },
  {
    id: "formation",
    title: "Formation field",
    blurb: "The provider swarm forming on the backdrop.",
    icon: Orbit,
    defaultSize: { w: 6, h: 3 },
    component: FormationCard,
  },
];

export const CARD_IDS: CardId[] = CARD_DEFS.map((d) => d.id);

export const CARD_ID_SET: ReadonlySet<string> = new Set(CARD_IDS);

export const CARD_DEF_BY_ID: Record<CardId, CardDef> = CARD_DEFS.reduce(
  (acc, def) => {
    acc[def.id] = def;
    return acc;
  },
  {} as Record<CardId, CardDef>,
);

export function isCardId(value: unknown): value is CardId {
  return typeof value === "string" && CARD_ID_SET.has(value);
}

export const KERNEL_ID_SET: ReadonlySet<string> = new Set(
  KERNEL_META.map((k) => k.id),
);

/** A sensible starting board — all cards, no overlaps, in a 12-col grid. */
export const DEFAULT_DASHBOARD_ITEMS: DashboardLayoutItem[] = [
  { cardId: "burn", rect: { x: 0, y: 0, w: 4, h: 3 } },
  { cardId: "usage-trend", rect: { x: 4, y: 0, w: 8, h: 3 } },
  { cardId: "tokens", rect: { x: 0, y: 3, w: 3, h: 2 } },
  { cardId: "requests", rect: { x: 3, y: 3, w: 3, h: 2 } },
  { cardId: "wand", rect: { x: 6, y: 3, w: 6, h: 2 } },
  { cardId: "providers", rect: { x: 0, y: 5, w: 4, h: 4 } },
  { cardId: "models", rect: { x: 4, y: 5, w: 4, h: 4 } },
  { cardId: "limits", rect: { x: 8, y: 5, w: 4, h: 4 } },
  { cardId: "devices", rect: { x: 0, y: 9, w: 6, h: 3 } },
  { cardId: "formation", rect: { x: 6, y: 9, w: 6, h: 3 } },
];

// The console default is a self-contained WebGL2 field (no glyph swarm needed).
// The engine's own DEFAULT_KERNEL_ID (constellation, 2D) remains the hard
// fallback when WebGL2 is unavailable — see resolveRenderableKernelId.
export const DEFAULT_APPEARANCE: DashboardAppearance = {
  kernelId: "fluid-aurora",
  frost: 0.5,
};

/** The fallback state used when nothing valid is persisted. */
export function buildFallbackState(): DashboardState {
  return {
    version: LAYOUT_SCHEMA_VERSION,
    items: DEFAULT_DASHBOARD_ITEMS.map((it) => ({
      cardId: it.cardId,
      rect: { ...it.rect },
    })),
    appearance: { ...DEFAULT_APPEARANCE },
  };
}

/** Layout rects of the currently-placed cards (for free-slot finding). */
export function rectsOf(items: { rect: GridRect }[]): GridRect[] {
  return items.map((it) => it.rect);
}
