import type { ReactNode } from "react";

export function AppShell({
  kicker,
  title,
  subtitle,
  headerAction,
  dragRegion = false,
  children
}: {
  kicker: string;
  title: string;
  subtitle: string;
  headerAction?: ReactNode;
  dragRegion?: boolean;
  children: ReactNode;
}) {
  return (
    <main className="shell">
      <section className="topbar">
        <div className="topbar-copy">
          {dragRegion ? <div className="window-drag-region" data-tauri-drag-region /> : null}
          <div className="topbar-head">
            <span className="kicker">{kicker}</span>
            {headerAction}
          </div>
          <h1>{title}</h1>
          <p>{subtitle}</p>
        </div>
      </section>

      <section className="workspace">{children}</section>
    </main>
  );
}
