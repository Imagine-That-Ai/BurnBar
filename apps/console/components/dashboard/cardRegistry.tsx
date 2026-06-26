/**
 * The catalog of dashboard cards: id → title, blurb, icon, default size, and
 * the body component. This is the single source the wizard lists, the grid
 * renders, and the persistence layer validates against.
 */

import {
  Boxes,
  Coins,
  Database,
  Flame,
  Gauge,
  Layers,
  LineChart,
  Orbit,
  Wand2,
  type LucideIcon,
} from "lucide-react";
import type { ComponentType } from "react";

import { DEFAULT_KERNEL_ID, KERNEL_SPECS } from "@/lib/gl/kernels";
import type { CardProps } from "./cardTypes";
import type { GridRect } from "./gridMath";
import {
  LAYOUT_SCHEMA_VERSION,
  type DashboardAppearance,
  type DashboardLayoutItem,
  type DashboardState,
} from "./layoutStore";
import { BurnTotalCard } from "./cards/BurnTotalCard";
import { CacheHitCard } from "./cards/CacheHitCard";
import { CostCurveCard } from "./cards/CostCurveCard";
import { FormationCard } from "./cards/FormationCard";
import { ProviderListCard } from "./cards/ProviderListCard";
import { SessionsCard } from "./cards/SessionsCard";
import { TokensCard } from "./cards/TokensCard";
import { TpsCard } from "./cards/TpsCard";
import { WandCard } from "./cards/WandCard";

export type CardId =
  | "burn"
  | "tokens"
  | "sessions"
  | "cost-curve"
  | "providers"
  | "cache"
  | "wand"
  | "tps"
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
    blurb: "Total spend for the window, with a trend.",
    icon: Flame,
    defaultSize: { w: 4, h: 3 },
    component: BurnTotalCard,
  },
  {
    id: "cost-curve",
    title: "Cost curve",
    blurb: "Cumulative spend over the window.",
    icon: LineChart,
    defaultSize: { w: 8, h: 3 },
    component: CostCurveCard,
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
    id: "sessions",
    title: "Sessions",
    blurb: "Conversation count and average size.",
    icon: Layers,
    defaultSize: { w: 3, h: 2 },
    component: SessionsCard,
  },
  {
    id: "cache",
    title: "Cache hit",
    blurb: "Prompt-cache reuse rate.",
    icon: Database,
    defaultSize: { w: 3, h: 2 },
    component: CacheHitCard,
  },
  {
    id: "tps",
    title: "Throughput",
    blurb: "Most-recent tokens / second.",
    icon: Gauge,
    defaultSize: { w: 3, h: 2 },
    component: TpsCard,
  },
  {
    id: "providers",
    title: "Provider list",
    blurb: "Spend by provider, ranked.",
    icon: Boxes,
    defaultSize: { w: 5, h: 4 },
    component: ProviderListCard,
  },
  {
    id: "wand",
    title: "The Wand",
    blurb: "Fusion routing savings vs baseline.",
    icon: Wand2,
    defaultSize: { w: 4, h: 3 },
    component: WandCard,
  },
  {
    id: "formation",
    title: "Formation field",
    blurb: "The provider swarm forming on the backdrop.",
    icon: Orbit,
    defaultSize: { w: 3, h: 3 },
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
  KERNEL_SPECS.map((k) => k.id),
);

/** A sensible starting board — all nine cards, no overlaps, in a 12-col grid. */
export const DEFAULT_DASHBOARD_ITEMS: DashboardLayoutItem[] = [
  { cardId: "burn", rect: { x: 0, y: 0, w: 4, h: 3 } },
  { cardId: "cost-curve", rect: { x: 4, y: 0, w: 8, h: 3 } },
  { cardId: "tokens", rect: { x: 0, y: 3, w: 3, h: 2 } },
  { cardId: "sessions", rect: { x: 3, y: 3, w: 3, h: 2 } },
  { cardId: "cache", rect: { x: 6, y: 3, w: 3, h: 2 } },
  { cardId: "tps", rect: { x: 9, y: 3, w: 3, h: 2 } },
  { cardId: "providers", rect: { x: 0, y: 5, w: 5, h: 4 } },
  { cardId: "wand", rect: { x: 5, y: 5, w: 4, h: 3 } },
  { cardId: "formation", rect: { x: 9, y: 5, w: 3, h: 3 } },
];

export const DEFAULT_APPEARANCE: DashboardAppearance = {
  kernelId: DEFAULT_KERNEL_ID,
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
