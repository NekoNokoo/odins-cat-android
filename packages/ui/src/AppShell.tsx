import type { ReactNode } from "react";

export function AppShell({
  kicker,
  title,
  subtitle,
  headerAction,
  dragRegion = false,
  compactHeader = false,
  children
}: {
  kicker?: string;
  title: string;
  subtitle?: string;
  headerAction?: ReactNode;
  dragRegion?: boolean;
  compactHeader?: boolean;
  children: ReactNode;
}) {
  return (
    <main className="shell">
      <section className="topbar">
        {compactHeader ? (
          <div className="topbar-copy topbar-copy--compact">
            <div className="topbar-head topbar-head--compact">
              <div className="topbar-title" {...(dragRegion ? { "data-tauri-drag-region": true } : {})}>
                <h1>{title}</h1>
              </div>
              {headerAction ? <div className="topbar-action">{headerAction}</div> : null}
            </div>
          </div>
        ) : (
          <div className="topbar-copy">
            {dragRegion ? <div className="window-drag-region" data-tauri-drag-region /> : null}
            <div className="topbar-head">
              {kicker ? <span className="kicker">{kicker}</span> : <span />}
              {headerAction}
            </div>
            <h1>{title}</h1>
            {subtitle ? <p>{subtitle}</p> : null}
          </div>
        )}
      </section>

      <section className="workspace">{children}</section>
    </main>
  );
}
