import type { Metadata } from "next";
import { I18nProvider } from "./_components/i18n";
import "@whitelist/ui/odin-one-theme.css";
import "./globals.css";

export const metadata: Metadata = {
  title: "Odin One VK",
  description: "Self-hosted VPN deployment desktop MVP"
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <I18nProvider>{children}</I18nProvider>
      </body>
    </html>
  );
}
