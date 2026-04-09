"use client";

import { AppShell } from "@whitelist/ui/AppShell";
import { LanguageToggle } from "./_components/i18n";
import { ControlCenter } from "./_components/control-center";

function HeaderWhitelistCat() {
  return (
    <span
      className="topbar-cat"
      aria-label="Odin's Cat"
      title="Odin's Cat"
    >
      <img src="/whitelist-cat-tight.png" alt="" aria-hidden="true" />
    </span>
  );
}

export default function Page() {
  return (
    <AppShell
      title="Odin's Cat"
      titleAccessory={<HeaderWhitelistCat />}
      headerAction={<LanguageToggle />}
      dragRegion
      compactHeader
    >
      <ControlCenter />
    </AppShell>
  );
}
