"use client";

import { LanguageToggle, useI18n } from "./_components/i18n";
import { ControlCenter } from "./_components/control-center";

export default function Page() {
  const { t } = useI18n();

  return (
    <main className="shell">
      <section className="topbar">
        <div className="topbar-copy">
          <div className="window-drag-region" data-tauri-drag-region />
          <div className="topbar-head">
            <span className="kicker">{t("appTag")}</span>
            <LanguageToggle />
          </div>
          <h1>Odin One</h1>
          <p>{t("appSubtitle")}</p>
        </div>
      </section>

      <section className="workspace">
        <ControlCenter />
      </section>
    </main>
  );
}
