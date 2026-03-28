"use client";

import { AppShell } from "@whitelist/ui/AppShell";
import { LanguageToggle, useI18n } from "./_components/i18n";
import { ControlCenter } from "./_components/control-center";

export default function Page() {
  const { t } = useI18n();

  return (
    <AppShell
      kicker={t("appTag")}
      title="Odin One VK"
      subtitle={t("appSubtitle")}
      headerAction={<LanguageToggle />}
      dragRegion
    >
      <ControlCenter />
    </AppShell>
  );
}
