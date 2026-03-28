"use client";

import { AppShell } from "@whitelist/ui/AppShell";
import { LanguageToggle, useI18n } from "@whitelist/ui/OdinI18n";
import { AndroidControlCenter } from "./_components/android-control-center";

export default function Page() {
  const { t } = useI18n();

  return (
    <AppShell
      kicker={t("appTagAndroid")}
      title="Odin One"
      subtitle={t("appSubtitleAndroid")}
      headerAction={<LanguageToggle />}
    >
      <AndroidControlCenter />
    </AppShell>
  );
}
