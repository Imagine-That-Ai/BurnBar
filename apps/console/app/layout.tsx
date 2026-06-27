import type { Metadata, Viewport } from "next";
import "@/styles/globals.css";
import { Providers } from "./providers";
import { AuthGate } from "@/components/AuthGate";
import { AppShell } from "@/components/AppShell";
import { DotCrestField } from "@/components/DotCrestField";

export const metadata: Metadata = {
  title: "BurnBar Console",
  description: "Your data, your keys — the BurnBar Data & Privacy Control Center.",
  // Favicon + touch icon are served by the Next file conventions app/icon.png
  // and app/apple-icon.png (the BurnBar flame mark).
  // The console is a private member surface; never index it.
  robots: { index: false, follow: false, nocache: true },
  referrer: "strict-origin-when-cross-origin",
};

export const viewport: Viewport = {
  themeColor: "#f6f5f1",
  colorScheme: "light",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <meta name="robots" content="noindex, nofollow, noarchive" />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,400..800&family=Fraunces:ital,opsz,wght@0,9..144,400..700;1,9..144,400..600&family=Geist:wght@300..800&family=Geist+Mono:wght@400..600&family=JetBrains+Mono:wght@400..600&family=Newsreader:ital,opsz,wght@0,6..72,400..700;1,6..72,400..600&family=Space+Grotesk:wght@400..700&family=Work+Sans:ital,wght@0,300..600;1,400..500&display=swap"
          rel="stylesheet"
        />
      </head>
      <body>
        <DotCrestField />
        <Providers>
          <AuthGate>
            <AppShell>{children}</AppShell>
          </AuthGate>
        </Providers>
      </body>
    </html>
  );
}
