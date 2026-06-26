import type { DashboardData } from "@/lib/dashboard/useDashboardUsage";

/** Every dashboard card body receives the resolved live usage data. */
export interface CardProps {
  data: DashboardData;
}
