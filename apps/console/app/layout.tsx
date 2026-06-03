import type { Metadata, Viewport } from "next";
import "@/styles/globals.css";
import { Providers } from "./providers";
import { AuthGate } from "@/components/AuthGate";
import { AppShell } from "@/components/AppShell";

export const metadata: Metadata = {
  title: "BurnBar Console",
  description: "Your data, your keys — the BurnBar Data & Privacy Control Center.",
  icons: {
    icon: "/brand/burnbar_cloud_crest.jpg",
    apple: "/brand/burnbar_cloud_crest.jpg",
  },
  // The console is a private member surface; never index it.
  robots: { index: false, follow: false, nocache: true },
  referrer: "strict-origin-when-cross-origin",
};

export const viewport: Viewport = {
  themeColor: "#050508",
  colorScheme: "dark",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <meta name="robots" content="noindex, nofollow, noarchive" />
      </head>
      <body>
        <Providers>
          <AuthGate>
            <AppShell>{children}</AppShell>
          </AuthGate>
        </Providers>
      </body>
    </html>
  );
}
