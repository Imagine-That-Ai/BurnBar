import type { DashboardSource, DashboardWindow } from "@/lib/dashboard/types";

/** Every dashboard card body receives the resolved window + its provenance. */
export interface CardProps {
  window: DashboardWindow;
  source: DashboardSource;
}
