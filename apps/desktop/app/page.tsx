"use client";

import { AppShell } from "@whitelist/ui/AppShell";
import { LanguageToggle } from "./_components/i18n";
import { ControlCenter } from "./_components/control-center";

export default function Page() {
  return (
    <AppShell
      title="Odin One"
      headerAction={<LanguageToggle />}
      dragRegion
      compactHeader
    >
      <ControlCenter />
    </AppShell>
  );
}
