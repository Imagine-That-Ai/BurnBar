"use client";

import { AuthProvider } from "@/lib/useAuth";
import { AnalyticsProvider } from "@/lib/analytics/AnalyticsProvider";
import { ThemeProvider } from "@/lib/useTheme";
import { BackdropProvider } from "@/lib/useBackdrop";

export function Providers({ children }: { children: React.ReactNode }) {
  // AnalyticsProvider is nested inside AuthProvider so it can read the signed-in
  // member (for hashed-uid identify). It stays dark until the member opts in.
  // ThemeProvider applies the console-wide theme; BackdropProvider owns the
  // console-wide animated kernel backdrop (both via state + localStorage).
  return (
    <AuthProvider>
      <AnalyticsProvider>
        <ThemeProvider>
          <BackdropProvider>{children}</BackdropProvider>
        </ThemeProvider>
      </AnalyticsProvider>
    </AuthProvider>
  );
}
