import type { Metadata } from "next";
import { I18nProvider } from "./_components/i18n";
import "@whitelist/ui/odin-one-theme.css";
import "./globals.css";

export const metadata: Metadata = {
  title: "Odin's Cat · HALO",
  description: "Self-hosted VPN client for Android and Windows"
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
