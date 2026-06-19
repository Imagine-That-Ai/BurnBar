"use client";

import { AuthProvider } from "@/lib/useAuth";
import { AnalyticsProvider } from "@/lib/analytics/AnalyticsProvider";

export function Providers({ children }: { children: React.ReactNode }) {
  // AnalyticsProvider is nested inside AuthProvider so it can read the signed-in
  // member (for hashed-uid identify). It stays dark until the member opts in.
  return (
    <AuthProvider>
      <AnalyticsProvider>{children}</AnalyticsProvider>
    </AuthProvider>
  );
}
